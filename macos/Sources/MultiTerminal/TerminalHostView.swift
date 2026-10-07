import AppKit
import SwiftTerm
import SwiftUI

struct TerminalHostView: NSViewRepresentable {
    let pane: TerminalPane
    @EnvironmentObject private var sessions: TerminalSessionRegistry
    @EnvironmentObject private var store: WorkspaceStore

    func makeNSView(context: Context) -> FocusableTerminalView {
        sessions.terminalView(for: pane, globalTheme: store.globalTheme)
    }

    func updateNSView(_ terminalView: FocusableTerminalView, context: Context) {
        sessions.applyTheme(pane.themeOverride ?? store.globalTheme, for: pane.id)
        terminalView.needsDisplay = true
    }
}
