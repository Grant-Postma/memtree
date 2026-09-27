import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            print("""
            memtree: a live treemap of what your Mac is doing.

              memtree                 open the window
              \(RecordOptions.usage.replacingOccurrences(of: "usage: ", with: ""))
            """)
            return
        }
        if args.contains("--record") {
            MainActor.assumeIsolated {
                do { try Recorder.run(try RecordOptions.parse(args)) } catch {
                    FileHandle.standardError.write(Data("memtree: \(error)\n\(RecordOptions.usage)\n".utf8))
                    exit(1)
                }
            }
            return
        }
        MemtreeApp.main()
    }
}

struct MemtreeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = LiveModel()

    var body: some Scene {
        WindowGroup("memtree") {
            ContentView(model: model).frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1400, height: 900)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started as a bare binary from a terminal, the process is not yet a
        // regular app and its window would open behind everything.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
