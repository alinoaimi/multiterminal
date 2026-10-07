import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class PaneContentRegistry: ObservableObject {
    @Published var cleanupError: String?
    private struct Entry {
        let workspaceID: UUID
        let view: NSView
        let dispose: () -> Void
    }

    private var entries: [UUID: Entry] = [:]
    private var profiles: [UUID: WKWebsiteDataStore] = [:]
    private let makeProfile: (UUID) -> WKWebsiteDataStore

    init(makeProfile: @escaping (UUID) -> WKWebsiteDataStore = { WKWebsiteDataStore(forIdentifier: $0) }) {
        self.makeProfile = makeProfile
    }

    func view(for pane: WorkspacePane, workspaceID: UUID, store: WorkspaceStore,
              sessions: TerminalSessionRegistry) -> NSView
    {
        if let entry = entries[pane.id] {
            switch pane {
            case let .terminal(terminal):
                (entry.view as? NSHostingView<AnyView>)?.rootView = terminalContent(
                    terminal,
                    workspaceID,
                    store,
                    sessions
                )
            case let .filePreview(file): (entry.view as? FilePreviewView)?.update(file)
            case .browser: break // Navigation state belongs to the existing web view.
            }
            return entry.view
        }
        let view: NSView
        let dispose: () -> Void
        switch pane {
        case let .terminal(terminal):
            view = NSHostingView(rootView: terminalContent(terminal, workspaceID, store, sessions))
            dispose = { sessions.terminate(paneID: terminal.id) }
        case let .filePreview(file):
            let preview = FilePreviewView(pane: file, update: { store.updatePane(.filePreview($0), in: workspaceID) })
            preview.openLink = { [weak self] url in
                self?.openBrowser(url, from: file.id, workspaceID: workspaceID, store: store)
            }
            view = preview
            dispose = { [weak preview] in preview?.close() }
        case let .browser(browser):
            let profile = profiles[workspaceID] ?? makeProfile(workspaceID)
            profiles[workspaceID] = profile
            let browserView = BrowserPaneView(pane: browser, dataStore: profile)
            browserView.urlChanged = { url in
                store.updatePane(.browser(BrowserPane(id: browser.id, url: url)), in: workspaceID)
            }
            browserView.openTab = { [weak self] url in
                self?.openBrowser(url, from: browser.id, workspaceID: workspaceID, store: store)
            }
            view = browserView
            dispose = { [weak browserView] in browserView?.close() }
        }
        entries[pane.id] = Entry(workspaceID: workspaceID, view: view, dispose: dispose)
        return view
    }

    func synchronize(_ workspace: Workspace) {
        let liveIDs = Set(workspace.panes.map(\.id))
        for id in entries.keys.filter({ entries[$0]?.workspaceID == workspace.id && !liveIDs.contains($0) }) {
            release(id)
        }
    }

    func closeWorkspace(_ id: UUID) {
        for paneID in entries.keys.filter({ entries[$0]?.workspaceID == id }) {
            release(paneID)
        }
        profiles.removeValue(forKey: id)
    }

    @discardableResult
    func deleteWorkspace(_ id: UUID) -> Task<Void, Never> {
        closeWorkspace(id)
        // WebKit requires all views using a profile to be released first.
        return Task { @MainActor in
            for attempt in 0 ..< 3 {
                do { try await WKWebsiteDataStore.remove(forIdentifier: id); return }
                catch {
                    if attempt == 2 {
                        cleanupError = "Browser data could not be removed: \(error.localizedDescription)"
                    } else { try? await Task.sleep(for: .milliseconds(300)) }
                }
            }
        }
    }

    func closeAll() { for id in Array(entries.keys) {
        release(id)
    }; profiles.removeAll() }

    private func release(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.view.removeFromSuperview()
        entry.dispose()
    }

    private func openBrowser(_ url: URL, from paneID: UUID, workspaceID: UUID, store: WorkspaceStore) {
        let groupID = store.workspace(id: workspaceID)?.layout?.group(containing: paneID)?.id
        store.insertPane(.browser(BrowserPane(url: url.absoluteString)), to: workspaceID, groupID: groupID, asTab: true)
    }

    private func terminalContent(_ pane: TerminalPane, _ workspaceID: UUID,
                                 _ store: WorkspaceStore, _ sessions: TerminalSessionRegistry) -> AnyView
    {
        AnyView(TerminalPaneView(workspaceID: workspaceID, pane: pane).environmentObject(store)
            .environmentObject(sessions))
    }
}

struct PaneTypeMenu: View {
    let workspaceID: UUID
    var groupID: UUID? = nil
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        Menu {
            ForEach(PaneKind.allCases) { kind in
                Button { PaneCreation.add(kind, workspaceID: workspaceID, groupID: groupID, store: store) } label: {
                    Label(kind.title, systemImage: kind.symbol)
                }
            }
        } label: { Label("Add Pane", systemImage: "plus") }
            .help("Add Terminal, File Preview, or Browser")
    }
}

@MainActor
enum PaneCreation {
    static func add(
        _ kind: PaneKind,
        workspaceID: UUID,
        groupID: UUID? = nil,
        edge: DockEdge? = nil,
        store: WorkspaceStore
    ) {
        let pane: WorkspacePane
        switch kind {
        case .terminal:
            pane = .terminal(TerminalPane())
        case .browser: pane = .browser(BrowserPane())
        case .filePreview:
            guard let file = chooseFile() else { return }
            pane = .filePreview(file)
        }
        store.insertPane(pane, to: workspaceID, groupID: groupID, edge: edge)
    }

    static func chooseFile(id: UUID = UUID()) -> FilePreviewPane? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose a file to preview"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { return try FilePreviewPane(id: id, path: url.path, bookmark: FileAccess.bookmark(for: url)) }
        catch { showError("File access could not be saved", error); return nil }
    }

    static func showError(_ title: String, _ error: Error) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = error.localizedDescription; alert
            .runModal()
    }
}

/// Tiny target/action wrapper retained by its control, for native pane chrome.
final class ActionButton: NSButton {
    var actionHandler: (() -> Void)?
    convenience init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = symbol == nil ? title : ""
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        toolTip = title
        setAccessibilityLabel(title)
        bezelStyle = .inline
        isBordered = false
        target = self
        self.action = #selector(invoke)
        actionHandler = action
    }

    @objc private func invoke() { actionHandler?() }
}
