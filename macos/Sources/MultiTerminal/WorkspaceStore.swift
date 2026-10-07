import Combine
import Foundation

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var workspaces: [Workspace]
    @Published private(set) var openWorkspaceIDs: [UUID]
    @Published private(set) var globalTheme: TerminalTheme

    @Published private(set) var persistenceError: String?
    @Published private(set) var loadBlocked = false
    @Published private(set) var recoveryBackupURL: URL?

    let storageURL: URL
    // Transient measurements only choose a new split's direction.
    var groupSizes: [UUID: CGSize] = [:]

    init(storageURL: URL? = nil) {
        #if DEBUG
            let testingPath = ProcessInfo.processInfo.environment["MULTITERMINAL_WORKSPACE_FILE"]
                ?? Bundle.main.object(forInfoDictionaryKey: "MultiTerminalWorkspaceFile") as? String
            let testingURL = testingPath.map { URL(fileURLWithPath: $0) }
            self.storageURL = storageURL ?? testingURL ?? Self.defaultStorageURL()
        #else
            self.storageURL = storageURL ?? Self.defaultStorageURL()
        #endif
        workspaces = []
        openWorkspaceIDs = []
        globalTheme = .midnight
        var state = PersistedWorkspaceState()
        do {
            state = try Self.load(from: self.storageURL)
        } catch {
            loadBlocked = true
            persistenceError =
                "Your saved workspaces could not be opened. The original file has not been changed. \(error.localizedDescription)"
        }
        workspaces = state.workspaces
        globalTheme = state.globalTheme
        openWorkspaceIDs = state.openWorkspaceIDs.filter { id in
            state.workspaces.contains { $0.id == id }
        }
    }

    var openWorkspaces: [Workspace] {
        openWorkspaceIDs.compactMap { workspace(id: $0) }
    }

    var closedWorkspaces: [Workspace] {
        workspaces.filter { !openWorkspaceIDs.contains($0.id) }
    }

    func workspace(id: UUID) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    @discardableResult
    func createWorkspace() -> Workspace {
        let ordinal = workspaces.count + 1
        let workspace = Workspace(name: "Workspace \(ordinal)")
        workspaces.append(workspace)
        openWorkspaceIDs.append(workspace.id)
        save()
        return workspace
    }

    func openWorkspace(id: UUID) {
        guard workspace(id: id) != nil, !openWorkspaceIDs.contains(id) else { return }
        openWorkspaceIDs.append(id)
        save()
    }

    func closeWorkspace(id: UUID) {
        openWorkspaceIDs.removeAll { $0 == id }
        save()
    }

    func deleteWorkspace(id: UUID) {
        workspaces.removeAll { $0.id == id }
        openWorkspaceIDs.removeAll { $0 == id }
        save()
    }

    func renameWorkspace(id: UUID, name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].name = trimmedName
        save()
    }

    @discardableResult
    func addPane(to workspaceID: UUID) -> TerminalPane? {
        let pane = TerminalPane()
        return insertPane(.terminal(pane), to: workspaceID) == nil ? nil : pane
    }

    @discardableResult
    func insertPane(_ pane: WorkspacePane, to workspaceID: UUID, groupID: UUID? = nil,
                    edge: DockEdge? = nil, asTab: Bool = false) -> WorkspacePane?
    {
        guard workspace(id: workspaceID) != nil else { return nil }
        mutate(workspaceID) { workspace in
            let target = workspace.layout?.groups.first { $0.id == (groupID ?? workspace.focusedGroupID) }
                ?? workspace.layout?.groups.first
            workspace.panes.append(pane)
            let group = PaneGroup(paneIDs: [pane.id])
            if let target, let layout = workspace.layout {
                if asTab {
                    workspace.layout = layout.updatingGroup(target.id) {
                        $0.paneIDs.append(pane.id); $0.selectedPaneID = pane.id
                    }
                    workspace.focusedGroupID = target.id
                } else {
                    let size = groupSizes[target.id] ?? CGSize(width: 600, height: 400)
                    let direction = edge ?? (size.width >= size.height ? .right : .bottom)
                    workspace.layout = layout.replacing(
                        id: target.id,
                        with: WorkspaceLayout.group(target).docking(.group(group), at: direction)
                    )
                    workspace.focusedGroupID = group.id
                }
            } else {
                workspace.layout = .group(group)
                workspace.focusedGroupID = group.id
            }
        }
        return pane
    }

    func removePane(id paneID: UUID, from workspaceID: UUID) {
        mutate(workspaceID) {
            $0.panes.removeAll { $0.id == paneID }
            $0.layout = $0.layout?.removing(paneIDs: [paneID])
        }
    }

    func movePane(id paneID: UUID, before targetPaneID: UUID, in workspaceID: UUID) {
        guard let target = workspace(id: workspaceID)?.layout?.group(containing: targetPaneID) else { return }
        dock(paneID: paneID, in: workspaceID, targetGroupID: target.id, beforePaneID: targetPaneID)
    }

    /// A move is one validated transaction: no observer sees a temporarily
    /// removed pane, so registries never release a live session during docking.
    func dock(paneID: UUID? = nil, groupID: UUID? = nil, in workspaceID: UUID,
              targetGroupID: UUID? = nil, edge: DockEdge? = nil, beforePaneID: UUID? = nil)
    {
        mutate(workspaceID) { workspace in
            guard let layout = workspace.layout,
                  let source = layout.groups.first(where: { group in
                      paneID.map { group.paneIDs.contains($0) } ?? (group.id == groupID)
                  }) else { return }
            let movingIDs = paneID.map { [$0] } ?? source.paneIDs
            if targetGroupID == source.id && (edge != nil || paneID == nil) && movingIDs.count == source.paneIDs
                .count { return }
            if beforePaneID == paneID && paneID != nil { return }
            guard targetGroupID == nil || layout.groups.contains(where: { $0.id == targetGroupID }) else { return }
            let remainder = layout.removing(paneIDs: Set(movingIDs))
            guard let remainder else { return }
            let movingGroup = PaneGroup(id: movingIDs.count == source.paneIDs.count ? source.id : UUID(),
                                        paneIDs: movingIDs, selectedPaneID: paneID ?? source.selectedPaneID)
            if let edge {
                if let targetGroupID {
                    guard let target = remainder.groups.first(where: { $0.id == targetGroupID }) else { return }
                    workspace.layout = remainder.replacing(
                        id: target.id,
                        with: WorkspaceLayout.group(target).docking(.group(movingGroup), at: edge)
                    )
                } else {
                    workspace.layout = remainder.docking(.group(movingGroup), at: edge)
                }
                workspace.focusedGroupID = movingGroup.id
            } else {
                guard let targetGroupID, remainder.groups.contains(where: { $0.id == targetGroupID }) else { return }
                workspace.layout = remainder.updatingGroup(targetGroupID) { target in
                    let index = beforePaneID.flatMap { target.paneIDs.firstIndex(of: $0) } ?? target.paneIDs.count
                    target.paneIDs.insert(contentsOf: movingIDs, at: index)
                    target.selectedPaneID = movingGroup.selectedPaneID
                }
                workspace.focusedGroupID = targetGroupID
            }
        }
    }

    func selectPane(_ paneID: UUID, in workspaceID: UUID) {
        mutate(workspaceID) { workspace in
            guard let group = workspace.layout?.group(containing: paneID) else { return }
            workspace.layout = workspace.layout?.updatingGroup(group.id) { $0.selectedPaneID = paneID }
            workspace.focusedGroupID = group.id
        }
    }

    func setSplitPercent(_ percent: Double, splitID: UUID, in workspaceID: UUID) {
        mutate(workspaceID) { $0.layout = $0.layout?.settingPercent(percent, splitID: splitID) }
    }

    func updatePane(_ pane: WorkspacePane, in workspaceID: UUID) {
        mutate(workspaceID) { workspace in
            guard let index = workspace.panes.firstIndex(where: { $0.id == pane.id }),
                  workspace.panes[index].kind == pane.kind else { return }
            workspace.panes[index] = pane
        }
    }

    func setDirectory(_ path: String, bookmark: Data? = nil, for paneID: UUID, in workspaceID: UUID) {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let paneIndex = workspaces[workspaceIndex].panes.firstIndex(where: { $0.id == paneID }) else { return }
        guard case var .terminal(pane) = workspaces[workspaceIndex].panes[paneIndex] else { return }
        pane.directoryPath = path
        pane.directoryBookmark = bookmark
        updatePane(.terminal(pane), in: workspaceID)
    }

    func setGlobalTheme(_ theme: TerminalTheme) {
        globalTheme = theme
        save()
    }

    func setThemeOverride(_ theme: TerminalTheme?, for paneID: UUID, in workspaceID: UUID) {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let paneIndex = workspaces[workspaceIndex].panes.firstIndex(where: { $0.id == paneID }) else { return }
        guard case var .terminal(pane) = workspaces[workspaceIndex].panes[paneIndex] else { return }
        pane.themeOverride = theme
        updatePane(.terminal(pane), in: workspaceID)
    }

    private func mutate(_ workspaceID: UUID, _ change: (inout Workspace) -> Void) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        var updated = workspaces[index]
        change(&updated)
        guard updated.layout?.isValid(paneIDs: updated.panes.map(\.id)) ?? updated.panes.isEmpty else { return }
        let panesByID = Dictionary(uniqueKeysWithValues: updated.panes.map { ($0.id, $0) })
        updated.panes = (updated.layout?.paneIDs ?? []).compactMap { panesByID[$0] }
        if !(updated.layout?.groups.contains { $0.id == updated.focusedGroupID } ?? false) {
            updated.focusedGroupID = updated.layout?.groups.first?.id
        }
        guard updated != workspaces[index] else { return }
        workspaces[index] = updated
        save()
    }

    private func save() {
        do { try flush() }
        catch { /* flush publishes the error for all save callers. */ }
    }

    /// Persist changes and let callers abort quitting on a write failure.
    func flush() throws {
        guard !loadBlocked else { throw CocoaError(.fileReadCorruptFile) }
        do {
            let state = PersistedWorkspaceState(
                workspaces: workspaces,
                openWorkspaceIDs: openWorkspaceIDs,
                globalTheme: globalTheme
            )
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: storageURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError =
                "Workspace changes could not be saved. Keep the app open and retry after fixing the storage problem. \(error.localizedDescription)"
            throw error
        }
    }

    func retryPersistence() {
        guard loadBlocked else {
            save()
            return
        }
        do {
            let state = try Self.load(from: storageURL)
            workspaces = state.workspaces
            globalTheme = state.globalTheme
            openWorkspaceIDs = state.openWorkspaceIDs.filter { id in
                state.workspaces.contains { $0.id == id }
            }
            loadBlocked = false
            persistenceError = nil
        } catch {
            persistenceError =
                "Your saved workspaces still could not be opened. The original file has not been changed. \(error.localizedDescription)"
        }
    }

    /// Called only after the user chooses recovery. Never replace the original
    /// unless a separate byte-for-byte backup was successfully created.
    func backUpAndStartFresh() {
        guard loadBlocked else { return }
        let backup = storageURL.deletingLastPathComponent()
            .appendingPathComponent("workspaces-recovery-\(UUID().uuidString).json")
        do {
            let original = try Data(contentsOf: storageURL)
            try original.write(to: backup, options: .withoutOverwriting)
            recoveryBackupURL = backup
            workspaces = []
            openWorkspaceIDs = []
            globalTheme = .midnight
            loadBlocked = false
            try flush()
        } catch {
            persistenceError =
                "Recovery could not finish. Keep the app open and fix the storage problem before retrying. \(error.localizedDescription)"
        }
    }

    private static func load(from url: URL) throws -> PersistedWorkspaceState {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return PersistedWorkspaceState()
        }
        return try JSONDecoder().decode(PersistedWorkspaceState.self, from: data)
    }

    static let storageDirectoryName = "MultiTerminal Source"

    private static func defaultStorageURL() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appendingPathComponent(
                storageDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent("workspaces.json")
    }
}
