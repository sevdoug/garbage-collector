import AppKit
import SwiftUI

@main
struct GarbageCollectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Garbage Collector", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    // `GarbageCollector /path` (or `open -a ... --args /path`) opens already scanning.
                    if let path = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("/") }) {
                        model.startScan(path: path)
                    }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Home Folder") { model.scanHome() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Scan Whole Disk") { model.scanWholeDisk() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Choose Folder…") { model.chooseFolderAndScan() }
                    .keyboardShortcut("o")
                Divider()
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r")
                    .disabled(model.phase != .browsing)
            }
            CommandMenu("Go") {
                Button("Enclosing Folder") { model.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!model.canGoUp)
                Button("Move to Trash") { model.requestTrashOfSelection() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.phase != .browsing || model.selectedNodes.isEmpty)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the binary runs outside a .app (e.g. `swift run`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .start: StartView()
            case .scanning: ScanningView()
            case .browsing: BrowserView()
            }
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }
}
