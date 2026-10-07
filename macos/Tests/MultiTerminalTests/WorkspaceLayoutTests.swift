import AppKit
@testable import MultiTerminal
import WebKit
import XCTest

final class WorkspaceLayoutTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    @MainActor private func store()
        -> WorkspaceStore { WorkspaceStore(storageURL: directory.appendingPathComponent("state.json")) }

    func testLegacyMigrationPreservesIDsFoldersThemesAndGrid() throws {
        let ids = (0 ..< 4).map { _ in UUID() }, workspaceID = UUID()
        let panes = ids
            .map {
                "{\"id\":\"\($0)\",\"directoryPath\":\"/tmp/work\",\"themeOverride\":\"amber\",\"directoryBookmark\":\"YWJj\"}"
            }.joined(separator: ",")
        let data = Data("{\"id\":\"\(workspaceID)\",\"name\":\"Old\",\"panes\":[\(panes)]}".utf8)
        let workspace = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(workspace.id, workspaceID); XCTAssertEqual(workspace.panes.map(\.id), ids)
        XCTAssertEqual(workspace.panes.first?.themeOverride, .amber)
        XCTAssertEqual(workspace.panes.first?.directoryBookmark, Data("abc".utf8))
        guard case let .split(rows) = workspace.layout,
              case let .split(columns) = rows.first else { return XCTFail("Expected two rows of columns") }
        XCTAssertEqual(rows.axis, .vertical); XCTAssertEqual(columns.axis, .horizontal)
        XCTAssertEqual(rows.firstPercent, 50); XCTAssertTrue(workspace.layout!.isValid(paneIDs: ids))
    }

    @MainActor func testMixedPanesAndNestedPercentagesRoundTrip() throws {
        let store = store(), workspace = store.createWorkspace()
        let file = FilePreviewPane(path: "/tmp/readme.md", bookmark: Data("bookmark".utf8))
        store.insertPane(.filePreview(file), to: workspace.id)
        let browser = BrowserPane(url: "http://localhost:3000")
        store.insertPane(.browser(browser), to: workspace.id)
        guard case let .split(root) = store.workspace(id: workspace.id)?.layout else { return XCTFail() }
        store.setSplitPercent(30, splitID: root.id, in: workspace.id)
        guard case let .split(nested) = root.second else { return XCTFail() }
        store.setSplitPercent(65, splitID: nested.id, in: workspace.id)
        let before = store.workspace(id: workspace.id)
        store.closeWorkspace(id: workspace.id)
        let restored = self.store(); restored.openWorkspace(id: workspace.id)
        XCTAssertEqual(restored.workspace(id: workspace.id), before)
        XCTAssertTrue(before!.layout!.isValid(paneIDs: before!.panes.map(\.id)))
        let json = try String(contentsOf: directory.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("firstPercent")); XCTAssertFalse(json.contains("pixels"))
        XCTAssertEqual(try JSONDecoder().decode(PersistedWorkspaceState.self, from: Data(json.utf8)).schemaVersion, 2)
    }

    @MainActor func testDefaultInsertionUsesFocusedGroupsLongerDimension() throws {
        let store = store(), w = store.createWorkspace()
        let group = try XCTUnwrap(w.focusedGroupID)
        store.groupSizes[group] = CGSize(width: 200, height: 600)
        store.addPane(to: w.id)
        guard case let .split(split) = store.workspace(id: w.id)?.layout else { return XCTFail() }
        XCTAssertEqual(split.axis, .vertical); XCTAssertEqual(split.firstPercent, 50)
    }

    @MainActor func testMergeReorderSelectionAndSplitOutPersist() throws {
        let store = store(), w = store.createWorkspace(), first = w.panes[0].id
        let second = try XCTUnwrap(store.addPane(to: w.id)).id
        let third = try XCTUnwrap(store.addPane(to: w.id)).id
        let groupID = try XCTUnwrap(store.workspace(id: w.id)?.layout?.group(containing: first)?.id)
        store.dock(paneID: second, in: w.id, targetGroupID: groupID)
        store.dock(paneID: third, in: w.id, targetGroupID: groupID, beforePaneID: first)
        XCTAssertEqual(store.workspace(id: w.id)?.layout?.groups.count, 1)
        XCTAssertEqual(store.workspace(id: w.id)?.layout?.paneIDs, [third, first, second])
        store.selectPane(second, in: w.id)
        XCTAssertEqual(self.store().workspace(id: w.id)?.layout?.groups.first?.selectedPaneID, second)
        store.dock(paneID: first, in: w.id, targetGroupID: groupID, edge: .bottom)
        XCTAssertEqual(store.workspace(id: w.id)?.layout?.groups.count, 2)
        XCTAssertEqual(Set(store.workspace(id: w.id)!.layout!.paneIDs), Set([first, second, third]))
        XCTAssertEqual(self.store().workspace(id: w.id), store.workspace(id: w.id))
    }

    @MainActor func testWholeGroupDockingAndCollapse() throws {
        let store = store(), w = store.createWorkspace(), firstGroup = w.layout!.groups[0].id
        let second = try XCTUnwrap(store.addPane(to: w.id)).id
        let third = BrowserPane()
        store.insertPane(.browser(third), to: w.id, groupID: firstGroup, asTab: true)
        store.dock(groupID: firstGroup, in: w.id, edge: .bottom)
        XCTAssertEqual(store.workspace(id: w.id)?.layout?.paneIDs, [second, w.panes[0].id, third.id])
        store.removePane(id: second, from: w.id)
        guard case let .group(group) = store.workspace(id: w.id)?.layout
        else { return XCTFail("Redundant split was not collapsed") }
        XCTAssertEqual(group.id, firstGroup)
        store.removePane(id: third.id, from: w.id); store.removePane(id: w.panes[0].id, from: w.id)
        XCTAssertNil(store.workspace(id: w.id)?.layout); XCTAssertNil(store.workspace(id: w.id)?.focusedGroupID)
        store.addPane(to: w.id); XCTAssertEqual(store.workspace(id: w.id)?.layout?.groups.count, 1)
    }

    @MainActor func testInvalidMovesAndPercentagesAreNoOps() {
        let store = store(), w = store.createWorkspace(); store.addPane(to: w.id)
        let before = store.workspace(id: w.id)!
        store.dock(paneID: before.panes[0].id, in: w.id, targetGroupID: UUID(), edge: .left)
        store.dock(paneID: UUID(), in: w.id, edge: .right)
        guard case let .split(split) = before.layout else { return XCTFail() }
        for percent in [0.0, 100, -1, Double.nan, Double.infinity] {
            store.setSplitPercent(
                percent,
                splitID: split.id,
                in: w.id
            )
        }
        XCTAssertEqual(store.workspace(id: w.id), before)
    }

    func testMalformedLayoutsRecoverWithoutLosingPanes() throws {
        var workspace = Workspace(name: "Recover", panes: [TerminalPane(), TerminalPane()])
        let id = workspace.panes[0].id
        workspace.layout = .group(PaneGroup(paneIDs: [id, id], selectedPaneID: UUID()))
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertEqual(decoded.panes, workspace.panes)
        XCTAssertTrue(decoded.layout!.isValid(paneIDs: workspace.panes.map(\.id)))
    }

    @MainActor func testNativeReparentingKeepsBrowserViewAndAllGroupsAttached() throws {
        let store = store(), w = store.createWorkspace()
        store.removePane(id: w.panes[0].id, from: w.id)
        let browser = BrowserPane(); store.insertPane(.browser(browser), to: w.id)
        let registry = PaneContentRegistry(makeProfile: { _ in .nonPersistent() }), sessions = TerminalSessionRegistry()
        defer { registry.closeAll() }
        let host = WorkspaceLayoutHost(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        func update() {
            host.update(store.workspace(id: w.id)!, store: store, sessions: sessions, contents: registry); host
                .layoutSubtreeIfNeeded()
        }
        update()
        let original = registry.view(for: .browser(browser), workspaceID: w.id, store: store, sessions: sessions)
        let second = BrowserPane(); store.insertPane(.browser(second), to: w.id); update()
        XCTAssertTrue(original.isDescendant(of: host)); XCTAssertEqual(host.groups.count, 2)
        for group in host.groups.values {
            XCTAssertTrue(group.isDescendant(of: host)); XCTAssertGreaterThan(
                group.frame.width,
                0
            )
        }
        store.dock(paneID: browser.id, in: w.id, edge: .bottom); update()
        XCTAssertTrue(original === registry.view(
            for: .browser(browser),
            workspaceID: w.id,
            store: store,
            sessions: sessions
        ))
        XCTAssertTrue(original.isDescendant(of: host))
        let group = store.workspace(id: w.id)!.layout!.group(containing: browser.id)!.id
        store.dock(paneID: second.id, in: w.id, targetGroupID: group); update()
        store.selectPane(browser.id, in: w.id); update()
        XCTAssertTrue(original.isDescendant(of: host)); XCTAssertEqual(host.groups.count, 1)
    }

    @MainActor func testWindowResizingDoesNotChangeSavedPercentages() throws {
        let split = PercentageSplitView(); split.isVertical = true; split.percent = 30
        split.setChildren(NSView(), NSView())
        var commits = 0; split.completedResize = { _ in commits += 1 }
        for width: CGFloat in [1000, 400, 200, 1200] {
            split.frame = NSRect(x: 0, y: 0, width: width, height: 500); split.layoutSubtreeIfNeeded()
            XCTAssertEqual(split.percent, 30)
        }
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(split.subviews[0].frame.width, (1200 - split.dividerThickness) * 0.3, accuracy: 1)
    }

    @MainActor func testNativeDropDestinationAcceptsAndPerformsCenterDrop() throws {
        let store = store(), w = store.createWorkspace()
        store.removePane(id: w.panes[0].id, from: w.id)
        let first = BrowserPane(), second = BrowserPane()
        store.insertPane(.browser(first), to: w.id); store.insertPane(.browser(second), to: w.id)
        let contents = PaneContentRegistry(makeProfile: { _ in .nonPersistent() }), sessions = TerminalSessionRegistry()
        defer { contents.closeAll() }
        let host = WorkspaceLayoutHost(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        host.update(store.workspace(id: w.id)!, store: store, sessions: sessions, contents: contents)
        host.layoutSubtreeIfNeeded()
        let overlay = WorkspaceDockOverlay(host: host); overlay.frame = host.bounds; host.addSubview(overlay)
        let workspace = store.workspace(id: w.id)!, source = workspace.layout!.group(containing: second.id)!
        let target = workspace.layout!.group(containing: first.id)!
        let group = host.groups[target.id]!, rect = group.convert(group.bounds, to: overlay)
        let location = overlay.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let info = TestDraggingInfo(
            location: location,
            payload: PaneDragPayload(workspaceID: w.id, paneID: second.id, groupID: source.id)
        )
        XCTAssertEqual(overlay.draggingEntered(info), .move)
        XCTAssertEqual(overlay.target?.groupID, target.id)
        XCTAssertTrue(overlay.prepareForDragOperation(info))
        XCTAssertTrue(overlay.performDragOperation(info))
        XCTAssertEqual(store.workspace(id: w.id)?.layout?.groups.count, 1)
        XCTAssertEqual(store.workspace(id: w.id)?.layout?.paneIDs, [first.id, second.id])
    }

    @MainActor func testBrowserProfilesShareWithinWorkspacePersistAndDelete() async throws {
        let store = store(), firstWorkspace = store.createWorkspace(), otherWorkspace = store.createWorkspace()
        let registry = PaneContentRegistry(), sessions = TerminalSessionRegistry()
        let first = WorkspacePane.browser(BrowserPane()), second = WorkspacePane.browser(BrowserPane()),
            other = WorkspacePane.browser(BrowserPane())
        let firstView = registry.view(
            for: first,
            workspaceID: firstWorkspace.id,
            store: store,
            sessions: sessions
        ) as! BrowserPaneView
        let secondView = registry.view(
            for: second,
            workspaceID: firstWorkspace.id,
            store: store,
            sessions: sessions
        ) as! BrowserPaneView
        let otherView = registry.view(
            for: other,
            workspaceID: otherWorkspace.id,
            store: store,
            sessions: sessions
        ) as! BrowserPaneView
        var profile: WKWebsiteDataStore? = firstView.webView.configuration.websiteDataStore
        XCTAssertTrue(profile!.isPersistent)
        XCTAssertTrue(profile === secondView.webView.configuration.websiteDataStore)
        let cookie = HTTPCookie(properties: [
            .name: "pane-test",
            .value: "saved",
            .domain: "localhost",
            .path: "/",
            .expires: Date(timeIntervalSinceNow: 3600),
        ])!
        await profile!.httpCookieStore.setCookie(cookie)
        let shared = await secondView.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let isolated = await otherView.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertTrue(shared.contains { $0.name == "pane-test" }); XCTAssertFalse(isolated
            .contains { $0.name == "pane-test" })
        registry.closeWorkspace(firstWorkspace.id)
        XCTAssertNil(firstView.webView); XCTAssertNil(secondView.webView)
        let reopened = registry.view(
            for: first,
            workspaceID: firstWorkspace.id,
            store: store,
            sessions: sessions
        ) as! BrowserPaneView
        let saved = await reopened.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertTrue(saved.contains { $0.name == "pane-test" })
        profile = nil
        await registry.deleteWorkspace(firstWorkspace.id).value
        await registry.deleteWorkspace(otherWorkspace.id).value
        XCTAssertNil(registry.cleanupError)
        XCTAssertNil(reopened.webView); XCTAssertNil(otherView.webView)
        let remaining = await WKWebsiteDataStore.allDataStoreIdentifiers
        XCTAssertFalse(remaining.contains(firstWorkspace.id)); XCTAssertFalse(remaining.contains(otherWorkspace.id))
    }
}

@MainActor
private final class TestDraggingInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(location: NSPoint, payload: PaneDragPayload) {
        draggingLocation = location; super.init()
        draggingPasteboard.setData(try! JSONEncoder().encode(payload), forType: PaneDragPayload.pasteboardType)
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    override nonisolated func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
