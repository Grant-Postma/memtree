import Darwin
import Foundation

/// One process at one moment.
struct ProcessInfoSample {
    let pid: pid_t
    let name: String
    let group: GroupID
    /// Cumulative CPU time, user + system, in nanoseconds.
    let cpuTimeNs: UInt64
    /// Physical footprint for our own processes (what Activity Monitor calls
    /// Memory); resident size for the ones only `ps` can see.
    let memoryBytes: UInt64
    /// False when the kernel refused `proc_pid_rusage` (another user's
    /// process) and the numbers came from `ps`.
    let precise: Bool
}

struct GroupID: Hashable {
    let key: String
    let name: String
    /// The `.app` bundle, for its icon.
    let appPath: String?
}

/// A process with its CPU share over the last interval.
struct ProcessStat {
    let pid: pid_t
    let name: String
    let group: GroupID
    let cpuPercent: Double
    let memoryBytes: UInt64
    let precise: Bool
}

struct Snapshot {
    let time: Date
    let processes: [ProcessStat]
    let cpuCount: Int
    let memoryTotal: UInt64
    let memoryUsed: UInt64
}

/// Reads the process table. Not thread-safe; owned by one queue.
final class Sampler {
    private var previous: [pid_t: (cpu: UInt64, name: String)] = [:]
    private var previousTime: UInt64 = 0
    private var groupCache: [pid_t: (name: String, group: GroupID)] = [:]
    private let timebase: (numer: UInt64, denom: UInt64)
    let cpuCount: Int
    let memoryTotal: UInt64

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = (UInt64(info.numer), UInt64(info.denom))
        cpuCount = ProcessInfo.processInfo.activeProcessorCount
        memoryTotal = ProcessInfo.processInfo.physicalMemory
    }

    func sample() -> Snapshot {
        let now = mach_absolute_time()
        let raw = readProcesses()
        let elapsedNs = Double((now &- previousTime) * timebase.numer / timebase.denom)

        var stats: [ProcessStat] = []
        stats.reserveCapacity(raw.count)
        var seen: [pid_t: (cpu: UInt64, name: String)] = [:]
        for proc in raw {
            seen[proc.pid] = (proc.cpuTimeNs, proc.name)
            var percent = 0.0
            // A reused pid carries another program's CPU time; compare names.
            if previousTime != 0, let before = previous[proc.pid], before.name == proc.name,
               proc.cpuTimeNs >= before.cpu, elapsedNs > 0 {
                percent = Double(proc.cpuTimeNs - before.cpu) / elapsedNs * 100
            }
            stats.append(ProcessStat(
                pid: proc.pid, name: proc.name, group: proc.group,
                cpuPercent: percent, memoryBytes: proc.memoryBytes, precise: proc.precise
            ))
        }
        previous = seen
        previousTime = now
        groupCache = groupCache.filter { seen[$0.key] != nil }

        return Snapshot(
            time: Date(), processes: stats, cpuCount: cpuCount,
            memoryTotal: memoryTotal, memoryUsed: Self.memoryUsed()
        )
    }

    private func readProcesses() -> [ProcessInfoSample] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }

        var result: [ProcessInfoSample] = []
        var missing: [pid_t] = []
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            let (name, group) = identify(pid)
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            if status == 0 {
                let ticks = usage.ri_user_time + usage.ri_system_time
                result.append(ProcessInfoSample(
                    pid: pid, name: name, group: group,
                    cpuTimeNs: ticks * timebase.numer / timebase.denom,
                    memoryBytes: usage.ri_phys_footprint, precise: true
                ))
            } else {
                missing.append(pid)
            }
        }

        if !missing.isEmpty {
            let fromPS = Self.readPS()
            for pid in missing {
                guard let entry = fromPS[pid] else { continue }
                let (name, group) = identify(pid)
                result.append(ProcessInfoSample(
                    pid: pid, name: name, group: group,
                    cpuTimeNs: entry.cpuNs, memoryBytes: entry.rss, precise: false
                ))
            }
        }
        return result
    }

    private func identify(_ pid: pid_t) -> (String, GroupID) {
        if let cached = groupCache[pid] { return cached }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : ""
        var name = (path as NSString).lastPathComponent
        if name.isEmpty {
            var nameBuffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            name = String(cString: nameBuffer)
        }
        if name.isEmpty { name = "pid \(pid)" }
        let entry = (name, Self.group(forPath: path))
        groupCache[pid] = entry
        return entry
    }

    /// The outermost `.app` in the path names the group, so every helper of
    /// Chrome or Slack lands under the app itself.
    static func group(forPath path: String) -> GroupID {
        if let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil) {
            let appPath = String(path[..<range.upperBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let bundle = "/" + appPath
            let name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            // Apps that live inside system frameworks are macOS itself.
            if bundle.hasPrefix("/System/Library/") && !bundle.hasPrefix("/System/Library/CoreServices/") {
                return GroupID(key: "macos", name: "macOS", appPath: nil)
            }
            return GroupID(key: bundle, name: name, appPath: bundle)
        }
        let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/private/"]
        if path.isEmpty || (systemPrefixes.contains(where: path.hasPrefix) && !path.hasPrefix("/usr/local/")) {
            return GroupID(key: "macos", name: "macOS", appPath: nil)
        }
        let name = (path as NSString).lastPathComponent
        return GroupID(key: "bin:" + name, name: name, appPath: nil)
    }

    /// `/bin/ps` is setuid root, so it sees processes `proc_pid_rusage`
    /// refuses to describe.
    private static func readPS() -> [pid_t: (rss: UInt64, cpuNs: UInt64)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,rss=,cputime="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var out: [pid_t: (UInt64, UInt64)] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, let pid = pid_t(fields[0]), let rssKB = UInt64(fields[1]),
                  let seconds = parseCPUTime(fields[2]) else { continue }
            out[pid] = (rssKB * 1024, UInt64(seconds * 1_000_000_000))
        }
        return out
    }

    /// `ps` prints CPU time as `M:SS.cc` or `H:MM:SS.cc`.
    static func parseCPUTime<S: StringProtocol>(_ text: S) -> Double? {
        var total = 0.0
        for part in text.split(separator: ":") {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Used memory the way Activity Monitor adds it up: app, wired and
    /// compressed pages.
    private static func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }
}
