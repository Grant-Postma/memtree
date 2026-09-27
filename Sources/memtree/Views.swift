import SwiftUI

struct ContentView: View {
    @ObservedObject var model: LiveModel
    @State private var pointer: CGPoint?
    @State private var texts = TextImages()

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model, interactive: true)
            Divider()
            // 60 fps is smooth enough for tiles easing over a second, and half
            // the work of a 120 Hz display.
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
                Canvas { context, size in
                    let groups = model.step(size: size, now: timeline.date)
                    let hovered = pointer.flatMap { model.hit($0) }
                    Painter(texts: texts, metric: model.metric, hovered: hovered).paint(groups, in: &context)
                }
            }
            .background(Color(white: 0.07))
            .onContinuousHover { phase in
                if case .active(let point) = phase { pointer = point } else { pointer = nil }
            }
            .onTapGesture(coordinateSpace: .local) { model.toggleFocus(at: $0) }
            Divider()
            footer
        }
        .background(Color(white: 0.1))
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let pointer, let hit = model.hit(pointer) {
                if let child = hit.child, let pid = child.pid, let stat = model.latest[pid] {
                    Text("\(hit.group.tile.label) › \(child.label)").bold()
                    Text("pid \(pid)").foregroundStyle(.secondary)
                    Text(String(format: "CPU %.1f%%", stat.cpuPercent))
                    Text("Memory \(LiveModel.bytes(stat.memoryBytes))\(stat.precise ? "" : " (resident, via ps)")")
                } else {
                    Text(hit.group.tile.label).bold()
                    Text(model.format(hit.group.tile.sampled))
                    Text("\(hit.group.children.count) processes").foregroundStyle(.secondary)
                }
            } else {
                Text("Point at a tile for details. Click an app to zoom in, Esc to come back.  m Memory · c CPU · i Idle · space Pause")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(size: 12).monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// The top bar. The recorder draws it too, without the controls.
struct Header: View {
    @ObservedObject var model: LiveModel
    let interactive: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text("memtree").font(.system(size: 13, weight: .bold))
            if interactive {
                if let focus = model.focus {
                    Button { model.focus = nil } label: {
                        Label("All › \(focus.name)", systemImage: "chevron.left")
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }
                Picker("", selection: $model.metric) {
                    ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if model.metric == .cpu {
                    Toggle("Idle", isOn: $model.showIdle).toggleStyle(.checkbox)
                }
                Button(model.paused ? "Resume" : "Pause") { model.paused.toggle() }
                    .keyboardShortcut(.space, modifiers: [])
            } else {
                Text(model.metric.rawValue).foregroundStyle(.secondary)
            }
            Spacer()
            stats
            if interactive { shortcuts }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var stats: some View {
        let s = model.summary
        return HStack(spacing: 16) {
            stat("CPU", String(format: "%.0f%% of %d cores", s.cpuPercent, s.cpuCount))
            stat("Memory", "\(LiveModel.bytes(s.memoryUsed)) of \(LiveModel.bytes(s.memoryTotal))")
            stat("Processes", "\(s.processCount)")
        }
        .font(.system(size: 12).monospacedDigit())
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    /// Plain-letter shortcuts, as buttons nobody sees.
    private var shortcuts: some View {
        ZStack {
            Button("") { model.metric = .cpu }.keyboardShortcut("c", modifiers: [])
            Button("") { model.metric = .memory }.keyboardShortcut("m", modifiers: [])
            Button("") { model.showIdle.toggle() }.keyboardShortcut("i", modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }
}
