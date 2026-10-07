import AppKit
import SwiftUI

@main
struct MultiTerminalApp: App {
    @NSApplicationDelegateAdaptor(MultiTerminalAppDelegate.self) private var appDelegate
    @StateObject private var workspaceStore = WorkspaceStore()
    @StateObject private var sessions = TerminalSessionRegistry()
    @StateObject private var contents = PaneContentRegistry()

    var body: some Scene {
        WindowGroup {
            WorkspaceRootView()
                .environmentObject(workspaceStore)
                .environmentObject(sessions)
                .environmentObject(contents)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    appDelegate.store = workspaceStore
                    appDelegate.sessions = sessions
                    appDelegate.contents = contents
                }
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Workspace") {
                    NotificationCenter.default.post(name: .createWorkspace, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("MultiTerminal Help") { openDocument("Help", extension: "html") }
                Button("Privacy") { openDocument("Privacy", extension: "html") }
                Button("Project License") { openDocument("LICENSE", extension: "txt") }
                Button("Third-Party Licenses") { openDocument("THIRD_PARTY_NOTICES", extension: "md") }
            }
        }
    }

    private func openDocument(_ name: String, extension fileExtension: String) {
        if let url = AppDocumentation.resourceURL(named: name, extension: fileExtension) {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
final class MultiTerminalAppDelegate: NSObject, NSApplicationDelegate {
    var store: WorkspaceStore?
    var sessions: TerminalSessionRegistry?
    var contents: PaneContentRegistry?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if (sessions?.activeSessionCount ?? 0) > 0 {
            let alert = NSAlert()
            alert.messageText = "Quit MultiTerminal?"
            alert
                .informativeText =
                "Open terminal sessions and running commands will stop. Workspace layouts will be saved, but running commands cannot be resumed."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        // A failed initial load leaves the app read-only. Quit without touching
        // that file; recovery remains an explicit choice on the next launch.
        if let store, !store.loadBlocked {
            do { try store.flush() }
            catch {
                let alert = NSAlert()
                alert.messageText = "Workspace layouts could not be saved"
                alert
                    .informativeText =
                    "MultiTerminal will stay open. Resolve the storage problem and retry.\n\(error.localizedDescription)"
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        contents?.closeAll()
        sessions?.terminateAll()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftPM executables launched from a shell need a regular app's
        // activation policy for windows and terminal input to work correctly.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    static let createWorkspace = Notification.Name("MultiTerminal.createWorkspace")
}
