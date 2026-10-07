import AppKit
@testable import MultiTerminal
import SwiftTerm
import XCTest

final class TerminalStartupTests: XCTestCase {
    @MainActor private final class CapturingTerminalView: FocusableTerminalView {
        var output = ""
        override func dataReceived(slice: ArraySlice<UInt8>) {
            output += String(decoding: slice, as: UTF8.self)
            super.dataReceived(slice: slice)
        }
    }

    @MainActor private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @MainActor func testDirectShellInterruptAndBracketedPasteIntegration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let view = CapturingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        defer { view.terminate() }
        view.startProcess(executable: "/bin/zsh", args: ["-f", "-i"], currentDirectory: directory.path)
        let ready = await eventually { view.output.contains("\u{1b}[?2004h") }
        XCTAssertTrue(ready)
        guard ready else { return }
        view.send(source: view, data: Array("printf '\\nREADY_FOR_INTERRUPT\\n'; /bin/sleep 10\r".utf8)[...])
        let sleeping = await eventually { view.output.contains("\r\nREADY_FOR_INTERRUPT\r\n") }
        XCTAssertTrue(sleeping)
        // Let sleep acquire the foreground process group before interrupting.
        try await Task.sleep(for: .milliseconds(200))
        let promptsBefore = view.output.components(separatedBy: "\u{1b}[?2004h").count
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                   modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil,
                                                   characters: "\u{3}", charactersIgnoringModifiers: "c",
                                                   isARepeat: false, keyCode: 8))
        view.keyDown(with: event)
        let interrupted = await eventually {
            view.output.components(separatedBy: "\u{1b}[?2004h").count > promptsBefore
        }
        XCTAssertTrue(interrupted, "Ctrl+C must interrupt sleep before its ten-second timeout")
        guard interrupted else { return }
        view.send(source: view, data: Array("\u{1b}[200~printf '\\nBRACKETED_PASTE_OK\\n'\u{1b}[201~\r".utf8)[...])
        let pasted = await eventually { view.output.contains("\r\nBRACKETED_PASTE_OK\r\n") }
        XCTAssertTrue(pasted)
        XCTAssertFalse(view.output.contains("^[[200~"))
        view.send(source: view, data: Array("exit\r".utf8)[...])
        let exited = await eventually { !view.process.running }
        XCTAssertTrue(exited)
    }

    func testMissingAndNonDirectoryPathsDoNotFallBackToHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let access = try DirectoryAccess(pane: TerminalPane(directoryPath: root.path))
        XCTAssertEqual(access.url.path, root.path)
        XCTAssertThrowsError(try DirectoryAccess(pane: TerminalPane(directoryPath: root
                .appendingPathComponent("missing").path)))
        let file = root.appendingPathComponent("file")
        try Data("fixture".utf8).write(to: file)
        XCTAssertThrowsError(try DirectoryAccess(pane: TerminalPane(directoryPath: file.path)))
    }

    func testStartupDenialIsDetectedAcrossEveryByteBoundary() {
        let bytes = Array("zsh: can't set tty pgrp: operation not permitted".utf8)
        for boundary in 1 ..< bytes.count {
            var diagnostic = ShellStartupDiagnostic()
            XCTAssertFalse(diagnostic.receive(bytes[..<boundary]))
            XCTAssertTrue(diagnostic.receive(bytes[boundary...]))
            XCTAssertFalse(diagnostic.isMonitoring)
        }
    }

    func testSuccessfulPromptAndBoundedOutputEndMonitoring() {
        var prompt = ShellStartupDiagnostic()
        XCTAssertFalse(prompt.receive(Array("prompt \u{1b}[?2004h".utf8)[...]))
        XCTAssertFalse(prompt.isMonitoring)
        XCTAssertFalse(prompt.receive(Array("zsh: can't set tty pgrp: operation not permitted".utf8)[...]))
        var verbose = ShellStartupDiagnostic()
        XCTAssertFalse(verbose.receive(Array(repeating: UInt8(65), count: 5000)[...]))
        XCTAssertFalse(verbose.isMonitoring)
    }

    @MainActor func testFailedShellStopsReceivingOutputAndInput() {
        let view = FocusableTerminalView(frame: .zero)
        view.monitorShellStartup = true
        view.dataReceived(slice: Array("zsh: can't set tty pgrp: operation not permitted\r\n".utf8)[...])
        XCTAssertNotNil(view.startupFailure)
        XCTAssertFalse(view.process.running)
        let failure = view.startupFailure
        view.send(source: view, data: [3][...])
        view.dataReceived(slice: Array("late shell output".utf8)[...])
        view.showStartupFailure("another error")
        XCTAssertEqual(view.startupFailure, failure)
    }

    @MainActor func testDirectTerminalDoesNotMonitorSandboxDiagnostic() {
        let view = FocusableTerminalView(frame: .zero)
        view.dataReceived(slice: Array("zsh: can't set tty pgrp: operation not permitted\r\n".utf8)[...])
        XCTAssertNil(view.startupFailure)
    }
}
