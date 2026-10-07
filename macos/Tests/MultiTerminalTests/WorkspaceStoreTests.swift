import Foundation
@testable import MultiTerminal
import XCTest

final class WorkspaceStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
    }

    @MainActor
    func testClosingKeepsWorkspaceAndRestoresOpenTabsFromDisk() {
        let url = storageURL()
        let store = WorkspaceStore(storageURL: url)
        let workspace = store.createWorkspace()
        store.addPane(to: workspace.id)
        store.closeWorkspace(id: workspace.id)

        let restored = WorkspaceStore(storageURL: url)
        XCTAssertEqual(restored.workspaces.count, 1)
        XCTAssertEqual(restored.workspaces.first?.panes.count, 2)
        XCTAssertTrue(restored.openWorkspaces.isEmpty)

        restored.openWorkspace(id: workspace.id)
        let reopened = WorkspaceStore(storageURL: url)
        XCTAssertEqual(reopened.openWorkspaceIDs, [workspace.id])
    }

    @MainActor
    func testDeletingRemovesWorkspaceAndItsOpenTab() {
        let store = WorkspaceStore(storageURL: storageURL())
        let workspace = store.createWorkspace()

        store.deleteWorkspace(id: workspace.id)

        XCTAssertNil(store.workspace(id: workspace.id))
        XCTAssertFalse(store.openWorkspaceIDs.contains(workspace.id))
    }

    @MainActor
    func testDirectoryAndPanesArePersisted() {
        let url = storageURL()
        let store = WorkspaceStore(storageURL: url)
        let workspace = store.createWorkspace()
        let pane = try! XCTUnwrap(store.addPane(to: workspace.id))

        store.setDirectory("/private/tmp/project with spaces", for: pane.id, in: workspace.id)

        let restored = WorkspaceStore(storageURL: url)
        let restoredPane = restored.workspace(id: workspace.id)?.panes.first { $0.id == pane.id }
        XCTAssertEqual(restoredPane?.directoryPath, "/private/tmp/project with spaces")
    }

    @MainActor
    func testMovingPaneChangesTheSavedOrder() {
        let store = WorkspaceStore(storageURL: storageURL())
        let workspace = store.createWorkspace()
        let second = try! XCTUnwrap(store.addPane(to: workspace.id))
        let first = try! XCTUnwrap(store.workspace(id: workspace.id)?.panes.first)

        store.movePane(id: second.id, before: first.id, in: workspace.id)

        XCTAssertEqual(store.workspace(id: workspace.id)?.panes.map(\.id), [second.id, first.id])
    }

    @MainActor
    func testGlobalAndPaneThemeOverridesArePersisted() {
        let url = storageURL()
        let store = WorkspaceStore(storageURL: url)
        let workspace = store.createWorkspace()
        let pane = try! XCTUnwrap(store.workspace(id: workspace.id)?.panes.first)

        store.setGlobalTheme(.amber)
        store.setThemeOverride(.highContrast, for: pane.id, in: workspace.id)

        let restored = WorkspaceStore(storageURL: url)
        XCTAssertEqual(restored.globalTheme, .amber)
        XCTAssertEqual(restored.workspace(id: workspace.id)?.panes.first?.themeOverride, .highContrast)
    }

    func testExistingWorkspaceFilesDefaultToMidnightTheme() throws {
        let legacyState = """
        {"workspaces":[],"openWorkspaceIDs":[]}
        """.data(using: .utf8)!

        XCTAssertEqual(try JSONDecoder().decode(PersistedWorkspaceState.self, from: legacyState).globalTheme, .midnight)
    }

    func testShellQuotingRoundTripsThroughShell() throws {
        let paths = ["/tmp/O'Reilly", "/tmp/project with spaces", "/tmp/$HOME`echo bad`", "/tmp/line\nbreak", ""]
        for path in paths {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s' " + ShellQuoting.quote(path)]
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), path)
        }
    }

    @MainActor
    func testDirectoryBookmarksPersistAndClearWhenFolderChanges() throws {
        let url = storageURL()
        let store = WorkspaceStore(storageURL: url)
        let workspace = store.createWorkspace()
        let pane = try XCTUnwrap(workspace.panes.first)
        let bookmark = Data("opaque-bookmark".utf8)
        store.setDirectory("/tmp/project", bookmark: bookmark, for: pane.id, in: workspace.id)
        let restored = WorkspaceStore(storageURL: url)
        XCTAssertEqual(restored.workspace(id: workspace.id)?.panes.first?.directoryBookmark, bookmark)
        restored.setDirectory("/tmp/other", for: pane.id, in: workspace.id)
        XCTAssertNil(WorkspaceStore(storageURL: url).workspace(id: workspace.id)?.panes.first?.directoryBookmark)
    }

    @MainActor
    func testCorruptFileBlocksSavesAndRecoveryPreservesOriginalBytes() throws {
        let url = storageURL()
        let original = Data("{broken json".utf8)
        try original.write(to: url)
        let store = WorkspaceStore(storageURL: url)
        XCTAssertTrue(store.loadBlocked)
        XCTAssertNotNil(store.persistenceError)
        _ = store.createWorkspace()
        XCTAssertThrowsError(try store.flush())
        XCTAssertEqual(try Data(contentsOf: url), original)

        store.backUpAndStartFresh()
        XCTAssertFalse(store.loadBlocked)
        XCTAssertNil(store.persistenceError)
        let backup = try XCTUnwrap(store.recoveryBackupURL)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertTrue(WorkspaceStore(storageURL: url).workspaces.isEmpty)
    }

    @MainActor
    func testFutureSchemaIsPreservedUntilCompatibleFileIsRestored() throws {
        let url = storageURL()
        let original = Data("{\"schemaVersion\":999,\"workspaces\":[]}".utf8)
        try original.write(to: url)
        let store = WorkspaceStore(storageURL: url)
        XCTAssertTrue(store.loadBlocked)
        XCTAssertThrowsError(try store.flush())
        XCTAssertEqual(try Data(contentsOf: url), original)
        try JSONEncoder().encode(PersistedWorkspaceState()).write(to: url)
        store.retryPersistence()
        XCTAssertFalse(store.loadBlocked)
        XCTAssertNil(store.persistenceError)
    }

    @MainActor
    func testUnreadableLocationCannotBeReplacedByRecovery() throws {
        let url = storageURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let sentinel = url.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        let store = WorkspaceStore(storageURL: url)
        XCTAssertTrue(store.loadBlocked)
        store.backUpAndStartFresh()
        XCTAssertTrue(store.loadBlocked)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertNil(store.recoveryBackupURL)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    @MainActor
    func testWriteFailureIsVisibleAndRetrySavesInMemoryChanges() throws {
        let url = storageURL()
        let store = WorkspaceStore(storageURL: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let workspace = store.createWorkspace()
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(store.workspaces.first?.id, workspace.id)
        try FileManager.default.removeItem(at: url)
        store.retryPersistence()
        XCTAssertNil(store.persistenceError)
        XCTAssertEqual(WorkspaceStore(storageURL: url).workspaces.first?.id, workspace.id)
    }

    @MainActor
    func testSourceBuildUsesItsOwnWorkspaceFolder() {
        XCTAssertEqual(WorkspaceStore.storageDirectoryName, "MultiTerminal Source")
    }

    @MainActor func testWorkspaceFlushPersistsAndReportsFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("settings/workspaces.json")
        let store = WorkspaceStore(storageURL: path)
        let workspace = store.createWorkspace()
        store.renameWorkspace(id: workspace.id, name: "Saved before quitting")
        try store.flush()
        XCTAssertEqual(WorkspaceStore(storageURL: path).workspaces.first?.name, "Saved before quitting")
        // Replace only this test's private directory with a file to simulate failure.
        try FileManager.default.removeItem(at: path.deletingLastPathComponent())
        try Data("not a directory".utf8).write(to: path.deletingLastPathComponent())
        XCTAssertThrowsError(try store.flush())
    }

    private func storageURL() -> URL {
        temporaryDirectory.appendingPathComponent("workspaces.json")
    }
}
