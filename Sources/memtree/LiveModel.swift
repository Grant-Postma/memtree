import AppKit
import SwiftUI

enum Metric: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    var id: String { rawValue }
}

struct Summary {
    var cpuPercent = 0.0
    var cpuCount = 0
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var processCount = 0
}

/// Identity of a tile across frames. Groups are numbered once, when first
/// seen, so a frame never hashes their (long, path-shaped) keys.
enum TileKey: Hashable {
    case group(Int)
    case process(pid_t)
    /// A group's processes too small to read, as one tile.
    case others(Int)
}

/// A tile as drawn this frame.
struct DrawnTile {
    let key: TileKey
    let rect: CGRect
    let label: String
    /// The eased value the tile is sized by.
    let value: Double
    /// The latest sampled value, for text: it changes once a second, so the
    /// label is not re-rendered every frame and does not flicker.
    let sampled: Double
    let color: Color
    let pid: pid_t?
}

struct DrawnGroup {
    let tile: DrawnTile
    /// Index into the model's groups; `nil` for Idle.
    let group: Int?
    let icon: Image?
    let header: CGFloat
    let children: [DrawnTile]
}

private struct Values {
    var cpu: Double
    var memory: Double

    static let zero = Values(cpu: 0, memory: 0)

    func mix(_ other: Values, _ t: Double) -> Values {
        Values(cpu: cpu + (other.cpu - cpu) * t, memory: memory + (other.memory - memory) * t)
    }
}

/// One process for the current interval, easing from `from` to `to`.
private struct Row {
    let pid: pid_t
    let group: Int
    let name: String
    let from: Values
    let to: Values
}

private struct GroupInfo {
    let id: GroupID
    let hue: Double
    var icon: Image?
}

@MainActor
final class LiveModel: ObservableObject {
    @Published var metric: Metric = .memory
    @Published var showIdle = false
    @Published var paused = false
    @Published var focus: GroupID?
    @Published private(set) var summary = Summary()

    static let interval: TimeInterval = 1.0
    static let minimumTileArea = 400.0
    private static let idleGroup = -1

    private let sampler = Sampler()
    private let queue = DispatchQueue(label: "memtree.sampler", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    /// The latest sample by pid, for the details line.
    private(set) var latest: [pid_t: ProcessStat] = [:]
    private var rows: [Row] = []
    private var groups: [GroupInfo] = []
    private var groupIndex: [String: Int] = [:]
    private var transitionStart = Date()

    /// Groups in screen space; processes as a fraction of their group, so
    /// a moving group carries its processes with it instead of trailing them.
    private var displayed: [TileKey: CGRect] = [:]
    private var groupOrder: [Int] = []
    private var childOrder: [Int: [Int]] = [:]
    private var rootLayout = StickyLayout()
    private var childLayouts: [Int: StickyLayout] = [:]
    /// Processes shown as their own tile; they fold back only well below
    /// the size that unfolds them, so none blinks at the threshold.
    private var unfolded = Set<pid_t>()
    private var lastFrame: Date?
    private(set) var frame: [DrawnGroup] = []

    func start() {
        guard timer == nil else { return }
        // The first sample has no earlier CPU time to compare with, so take a
        // second one soon after rather than show an empty map for a second.
        queue.async { [sampler] in _ = sampler.sample() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.3, repeating: Self.interval)
        timer.setEventHandler { [weak self, sampler] in
            let snapshot = sampler.sample()
            DispatchQueue.main.async { self?.ingest(snapshot, at: Date()) }
        }
        timer.resume()
        self.timer = timer
    }

    /// Takes a sample as of `now`; the recorder passes its own clock.
    func ingest(_ snapshot: Snapshot, at now: Date) {
        guard !paused else { return }
        let t = progress(at: now)
        var current: [pid_t: (values: Values, name: String)] = [:]
        current.reserveCapacity(rows.count)
        for row in rows { current[row.pid] = (row.from.mix(row.to, t), row.name) }

        var next: [Row] = []
        next.reserveCapacity(snapshot.processes.count + 16)
        var byPid: [pid_t: ProcessStat] = [:]
        var cpuTotal = 0.0
        for proc in snapshot.processes {
            let target = Values(cpu: proc.cpuPercent, memory: Double(proc.memoryBytes))
            // A reused pid is a new process: it grows from nothing.
            let start = current[proc.pid].flatMap { $0.name == proc.name ? $0.values : nil } ?? .zero
            next.append(Row(pid: proc.pid, group: index(of: proc.group), name: proc.name, from: start, to: target))
            byPid[proc.pid] = proc
            cpuTotal += proc.cpuPercent
        }
        // Exited processes shrink away instead of vanishing.
        for row in rows where byPid[row.pid] == nil {
            let start = row.from.mix(row.to, t)
            if start.cpu > 0.01 || start.memory > 1 {
                next.append(Row(pid: row.pid, group: row.group, name: row.name, from: start, to: .zero))
            }
        }
        rows = next
        latest = byPid
        transitionStart = now
        summary = Summary(
            cpuPercent: cpuTotal, cpuCount: snapshot.cpuCount,
            memoryUsed: snapshot.memoryUsed, memoryTotal: snapshot.memoryTotal,
            processCount: snapshot.processes.count
        )
    }

    private func index(of id: GroupID) -> Int {
        if let existing = groupIndex[id.key] { return existing }
        groups.append(GroupInfo(id: id, hue: Self.hue(for: id.key), icon: nil))
        groupIndex[id.key] = groups.count - 1
        return groups.count - 1
    }

    private func progress(at now: Date) -> Double {
        let t = min(max(now.timeIntervalSince(transitionStart) / Self.interval, 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Frame

    /// Lays out and eases every tile for one frame.
    func step(size: CGSize, now: Date) -> [DrawnGroup] {
        let dt = min(lastFrame.map { now.timeIntervalSince($0) } ?? 0, 0.1)
        lastFrame = now
        let ease = CGFloat(1 - exp(-dt * 9))
        // Read once: a @Published getter goes through a key path, which adds
        // up across hundreds of processes sixty times a second.
        let metric = self.metric, showIdle = self.showIdle, summary = self.summary
        let paused = self.paused
        let focusIndex = self.focus.flatMap { groupIndex[$0.key] }
        let cpu = metric == .cpu
        let t = paused ? 1 : progress(at: now)

        var sums = [Double](repeating: 0, count: groups.count)
        var sampledSums = [Double](repeating: 0, count: groups.count)
        var members = [[Int]](repeating: [], count: groups.count)
        var values = [Double](repeating: 0, count: rows.count)
        for (i, row) in rows.enumerated() {
            if let focusIndex, row.group != focusIndex { continue }
            let v = cpu ? row.from.cpu + (row.to.cpu - row.from.cpu) * t
                        : row.from.memory + (row.to.memory - row.from.memory) * t
            guard v > 0 else { continue }
            values[i] = v
            sums[row.group] += v
            sampledSums[row.group] += cpu ? row.to.cpu : row.to.memory
            members[row.group].append(i)
        }

        struct Entry { let group: Int; let sum: Double; let sampled: Double }
        var ordered: [Entry] = []
        for g in sums.indices where sums[g] > 0 { ordered.append(Entry(group: g, sum: sums[g], sampled: sampledSums[g])) }
        if showIdle, cpu, focusIndex == nil {
            let capacity = Double(summary.cpuCount) * 100
            ordered.append(Entry(group: Self.idleGroup, sum: max(capacity - sums.reduce(0, +), 0),
                                 sampled: max(capacity - summary.cpuPercent, 0)))
        }
        let byGroup = Dictionary(uniqueKeysWithValues: ordered.map { ($0.group, $0) })
        groupOrder = Self.stableOrder(previous: groupOrder, sizes: byGroup.mapValues(\.sum))
        ordered = groupOrder.compactMap { byGroup[$0] }

        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
        let groupTargets = rootLayout.layout(keys: ordered.map(\.group), values: ordered.map(\.sum), in: bounds)

        var seen = Set<TileKey>()
        seen.reserveCapacity(rows.count + ordered.count)
        var out: [DrawnGroup] = []
        for (entry, target) in zip(ordered, groupTargets) where target.width > 0 && target.height > 0 {
            let key = TileKey.group(entry.group)
            let rect = eased(key, toward: target, by: ease)
            seen.insert(key)

            let header: CGFloat = rect.height > 40 && rect.width > 60 ? 20 : 0
            let inner = CGRect(x: rect.minX + 2, y: rect.minY + header + 1,
                               width: max(rect.width - 4, 0), height: max(rect.height - header - 3, 0))

            if entry.group == Self.idleGroup {
                let childKey = TileKey.process(-1)
                seen.insert(childKey)
                let child = DrawnTile(key: childKey, rect: inner, label: "Idle",
                                      value: entry.sum, sampled: entry.sampled, color: Color(white: 0.2), pid: nil)
                out.append(DrawnGroup(
                    tile: DrawnTile(key: key, rect: rect, label: "Idle", value: entry.sum, sampled: entry.sampled,
                                    color: Color(white: 0.14), pid: nil),
                    group: nil, icon: nil, header: header, children: [child]))
                continue
            }

            let info = groups[entry.group]
            var rowOf: [Int: Int] = [:]
            for i in members[entry.group] { rowOf[Int(rows[i].pid)] = i }
            let order = Self.stableOrder(previous: childOrder[entry.group] ?? [],
                                         sizes: rowOf.mapValues { values[$0] })
            childOrder[entry.group] = order
            // Processes under about 20×20 pt fold into one tile. Hundreds of
            // slivers are unreadable, and a squarified layout reshuffles all
            // of them whenever a large tile changes, which smears the map.
            let perPoint = entry.sum > 0 ? Double(inner.width * inner.height) / entry.sum : 0
            var children: [Int] = []
            var folded = 0, foldedValue = 0.0, foldedSampled = 0.0
            for i in order.compactMap({ rowOf[$0] }) {
                let pid = rows[i].pid
                let threshold = unfolded.contains(pid) ? Self.minimumTileArea * 0.6 : Self.minimumTileArea
                if values[i] * perPoint >= threshold {
                    children.append(i)
                    unfolded.insert(pid)
                } else {
                    unfolded.remove(pid)
                    folded += 1
                    foldedValue += values[i]
                    foldedSampled += cpu ? rows[i].to.cpu : rows[i].to.memory
                }
            }
            var layoutValues = children.map { values[$0] }
            if folded > 0 { layoutValues.append(foldedValue) }
            let unit = CGRect(x: 0, y: 0, width: max(inner.width, 1), height: max(inner.height, 1))
            let layoutKeys = children.map { Int(rows[$0].pid) } + (folded > 0 ? [-1] : [])
            let childTargets = childLayouts[entry.group, default: StickyLayout()]
                .layout(keys: layoutKeys, values: layoutValues, in: unit).map {
                CGRect(x: $0.minX / unit.width, y: $0.minY / unit.height,
                       width: $0.width / unit.width, height: $0.height / unit.height)
            }
            var drawnChildren: [DrawnTile] = []
            drawnChildren.reserveCapacity(children.count)
            for (i, childTarget) in zip(children, childTargets) where childTarget.width > 0 {
                let row = rows[i]
                let childKey = TileKey.process(row.pid)
                seen.insert(childKey)
                let local = eased(childKey, toward: childTarget, by: ease)
                let childRect = CGRect(x: inner.minX + local.minX * inner.width, y: inner.minY + local.minY * inner.height,
                                       width: local.width * inner.width, height: local.height * inner.height)
                    .intersection(inner)
                guard !childRect.isNull else { continue }
                drawnChildren.append(DrawnTile(
                    key: childKey, rect: childRect, label: row.name, value: values[i],
                    sampled: cpu ? row.to.cpu : row.to.memory,
                    color: color(hue: info.hue, value: values[i], pid: row.pid, metric: metric),
                    pid: row.pid
                ))
            }
            if folded > 0, let target = childTargets.last, target.width > 0 {
                let othersKey = TileKey.others(entry.group)
                seen.insert(othersKey)
                let local = eased(othersKey, toward: target, by: ease)
                let othersRect = CGRect(x: inner.minX + local.minX * inner.width, y: inner.minY + local.minY * inner.height,
                                        width: local.width * inner.width, height: local.height * inner.height)
                    .intersection(inner)
                if !othersRect.isNull {
                    drawnChildren.append(DrawnTile(
                        key: othersKey, rect: othersRect, label: "+\(folded) more", value: foldedValue,
                        sampled: foldedSampled, color: Color(hue: info.hue, saturation: 0.30, brightness: 0.27), pid: nil))
                }
            }
            out.append(DrawnGroup(
                tile: DrawnTile(key: key, rect: rect, label: info.id.name, value: entry.sum, sampled: entry.sampled,
                                color: Color(hue: info.hue, saturation: 0.40, brightness: 0.34), pid: nil),
                group: entry.group, icon: icon(forGroup: entry.group), header: header, children: drawnChildren
            ))
        }
        if displayed.count > seen.count { displayed = displayed.filter { seen.contains($0.key) } }
        frame = out
        return out
    }

    /// Largest first, but sticky: a tile passes the one ahead of it only once
    /// it is clearly larger. Near-equal tiles otherwise swap places every
    /// sample and fly across the map.
    static func stableOrder(previous: [Int], sizes: [Int: Double], margin: Double = 1.15) -> [Int] {
        var order = previous.filter { sizes[$0] != nil }
        let known = Set(order)
        order += sizes.keys.filter { !known.contains($0) }.sorted { sizes[$0]! > sizes[$1]! || (sizes[$0]! == sizes[$1]! && $0 < $1) }
        for i in order.indices.dropFirst() {
            var j = i
            while j > 0, sizes[order[j]]! > sizes[order[j - 1]]! * margin {
                order.swapAt(j, j - 1)
                j -= 1
            }
        }
        return order
    }

    private func eased(_ key: TileKey, toward target: CGRect, by amount: CGFloat) -> CGRect {
        // New tiles grow out of their own centre.
        let current = displayed[key] ?? CGRect(x: target.midX, y: target.midY, width: 0, height: 0)
        let rect = CGRect(x: current.minX + (target.minX - current.minX) * amount,
                          y: current.minY + (target.minY - current.minY) * amount,
                          width: current.width + (target.width - current.width) * amount,
                          height: current.height + (target.height - current.height) * amount)
        displayed[key] = rect
        return rect
    }

    private func color(hue: Double, value: Double, pid: pid_t, metric: Metric) -> Color {
        let jitter = Double(Int(pid) % 7) * 0.012
        switch metric {
        case .cpu:
            // Busy processes glow: brightness and saturation follow load.
            let load = min(value / 100, 1)
            return Color(hue: hue, saturation: 0.35 + 0.35 * load, brightness: 0.42 + 0.45 * load + jitter)
        case .memory:
            return Color(hue: hue, saturation: 0.38, brightness: 0.52 + jitter)
        }
    }

    /// A hue that stays put for a group across runs (unlike `hashValue`).
    nonisolated static func hue(for key: String) -> Double {
        if key == "macos" { return 0.6 }
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Double(hash % 360) / 360
    }

    // MARK: - Interaction

    func hit(_ point: CGPoint) -> (group: DrawnGroup, child: DrawnTile?)? {
        guard let group = frame.first(where: { $0.tile.rect.contains(point) }) else { return nil }
        return (group, group.children.first { $0.rect.contains(point) })
    }

    func toggleFocus(at point: CGPoint) {
        if focus != nil { focus = nil; return }
        guard let index = hit(point)?.group.group else { return }
        focus = groups[index].id
    }

    private func icon(forGroup index: Int) -> Image? {
        if let cached = groups[index].icon { return cached }
        guard let path = groups[index].id.appPath else { return nil }
        // A bitmap at the drawn size: Canvas otherwise redraws the icon's
        // vector representations every frame.
        let source = NSWorkspace.shared.icon(forFile: path)
        var rect = CGRect(x: 0, y: 0, width: 32, height: 32)
        let image = source.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            .map { Image(decorative: $0, scale: 2) } ?? Image(nsImage: source)
        groups[index].icon = image
        return image
    }

    func format(_ value: Double) -> String {
        Self.format(value, metric: metric)
    }

    nonisolated static func format(_ value: Double, metric: Metric) -> String {
        switch metric {
        case .cpu: return String(format: value >= 10 ? "%.0f%%" : "%.1f%%", value)
        case .memory: return bytes(UInt64(max(value, 0)))
        }
    }

    nonisolated static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
}
