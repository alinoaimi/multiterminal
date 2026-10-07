import AppKit
import Combine
import Darwin
import SwiftTerm

@MainActor
final class TerminalSessionRegistry: ObservableObject {
    private var sessions: [UUID: TerminalSession] = [:]
    var activeSessionCount: Int { sessions.values.filter(\.terminalView.process.running).count }

    func terminalView(for pane: TerminalPane, globalTheme: TerminalTheme) -> FocusableTerminalView {
        if let existing = sessions[pane.id] {
            existing.apply(theme: pane.themeOverride ?? globalTheme)
            return existing.terminalView
        }

        let session = TerminalSession(pane: pane, theme: pane.themeOverride ?? globalTheme)
        sessions[pane.id] = session
        session.start()
        return session.terminalView
    }

    func changeDirectoryNow(_ directory: String, for paneID: UUID) {
        sessions[paneID]?.changeDirectory(to: directory)
    }

    func applyTheme(_ theme: TerminalTheme, for paneID: UUID) {
        sessions[paneID]?.apply(theme: theme)
    }

    func terminate(paneID: UUID) {
        sessions.removeValue(forKey: paneID)?.terminate()
    }

    func terminateWorkspace(_ workspace: Workspace) {
        workspace.panes.forEach { terminate(paneID: $0.id) }
    }

    func terminateAll() {
        let activeSessions = sessions.values
        sessions.removeAll()
        activeSessions.forEach { $0.terminate() }
    }
}

@MainActor
private final class TerminalSession {
    let terminalView: FocusableTerminalView
    private var directoryAccess: DirectoryAccess?
    private var startupError: String?
    private var didStart = false

    init(pane: TerminalPane, theme: TerminalTheme) {
        terminalView = FocusableTerminalView(frame: .zero)
        terminalView.wantsLayer = true
        apply(theme: theme)
        do {
            directoryAccess = try DirectoryAccess(pane: pane)
        } catch {
            startupError =
                "The project folder is missing or inaccessible. Use Set Default Folder, then close and reopen this workspace. No shell was started in a substitute folder."
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        // Starting after the view joins the run loop gives SwiftTerm a useful
        // initial terminal size instead of the temporary zero-sized frame.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let startupError = self.startupError {
                self.terminalView.showStartupFailure(startupError)
                return
            }
            guard let directory = self.directoryAccess?.url else { return }
            #if APP_STORE
                self.terminalView.monitorShellStartup = true
            #endif
            self.terminalView.startProcess(
                executable: Self.loginShellPath(),
                args: ["-i", "-l"],
                currentDirectory: directory.path
            )
            if !self.terminalView.process.running {
                self.terminalView
                    .showStartupFailure("Unable to start the shell. Check folder permissions and shell availability.")
            }
        }
    }

    func changeDirectory(to path: String) {
        let command = "cd -- \(ShellQuoting.quote(path))\n"
        terminalView.send(source: terminalView, data: ArraySlice(command.utf8))
    }

    func apply(theme: TerminalTheme) {
        terminalView.nativeForegroundColor = theme.foregroundColor
        terminalView.nativeBackgroundColor = theme.backgroundColor
    }

    func terminate() {
        terminalView.terminate()
    }

    private static func loginShellPath() -> String {
        guard let account = getpwuid(getuid()), let shell = account.pointee.pw_shell else {
            return "/bin/zsh"
        }
        let path = String(cString: shell)
        return path.isEmpty ? "/bin/zsh" : path
    }
}

private extension TerminalTheme {
    var foregroundColor: NSColor {
        switch self {
        case .midnight: NSColor(calibratedRed: 0.90, green: 0.93, blue: 0.96, alpha: 1)
        case .highContrast: .white
        case .amber: NSColor(calibratedRed: 1.0, green: 0.73, blue: 0.34, alpha: 1)
        }
    }

    var backgroundColor: NSColor {
        switch self {
        case .midnight: NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.09, alpha: 1)
        case .highContrast: .black
        case .amber: NSColor(calibratedRed: 0.06, green: 0.04, blue: 0.01, alpha: 1)
        }
    }
}

/// SwiftTerm accepts first responder status, but its standard mouse handler is
/// intentionally focused on terminal selection.  Explicitly taking focus on a
/// click makes a pane behave like Terminal.app: click, then type.
class FocusableTerminalView: LocalProcessTerminalView {
    var monitorShellStartup = false
    private var startupDiagnostic = ShellStartupDiagnostic()
    private(set) var startupFailure: String?

    func showStartupFailure(_ message: String) {
        guard startupFailure == nil else { return }
        startupFailure = message
        terminate()
        // Disable paste wrapping and discard a half-rendered shell prompt.
        feed(text: "\u{1b}[?2004l\u{1b}[2J\u{1b}[H\(message)\r\n")
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        guard startupFailure == nil else { return }
        if monitorShellStartup, startupDiagnostic.receive(slice) {
            showStartupFailure(
                "macOS denied shell terminal job control in this sandboxed build.\r\nThe shell was stopped because paste and Ctrl+C cannot work reliably.\r\nThis build is not ready for App Store distribution."
            )
            return
        }
        super.dataReceived(slice: slice)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard startupFailure == nil else { return }
        // Stop monitoring after input: later command output is not startup.
        monitorShellStartup = false
        super.send(source: source, data: data)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

/// Bounded startup-only matching, including messages split across PTY reads.
struct ShellStartupDiagnostic {
    private var pending: [UInt8] = []
    private(set) var isMonitoring = true
    private var receivedByteCount = 0

    mutating func receive(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard isMonitoring else { return false }
        let remaining = max(0, 4096 - receivedByteCount)
        let prefix = bytes.prefix(remaining)
        pending.append(contentsOf: prefix)
        receivedByteCount += prefix.count
        let text = String(decoding: pending, as: UTF8.self)
        if text.contains("zsh: can't set tty pgrp: operation not permitted") {
            isMonitoring = false
            return true
        }
        if text.contains("\u{1b}[?2004h") || receivedByteCount >= 4096 {
            isMonitoring = false
        }
        pending = Array(pending.suffix(256))
        return false
    }
}
