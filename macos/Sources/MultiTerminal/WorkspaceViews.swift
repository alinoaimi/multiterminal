import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceRootView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var sessions: TerminalSessionRegistry
    @EnvironmentObject private var contents: PaneContentRegistry

    @State private var selectedWorkspaceID: UUID?
    @State private var workspaceToClose: UUID?
    @State private var workspaceToDelete: UUID?
    @State private var workspaceToRename: Workspace?

    var body: some View {
        Group {
            if store.openWorkspaces.isEmpty {
                MultiTerminalWelcomeView(createWorkspace: createWorkspace)
            } else {
                TabView(selection: $selectedWorkspaceID) {
                    ForEach(store.openWorkspaces) { workspace in
                        WorkspaceView(
                            workspace: workspace,
                            rename: { workspaceToRename = workspace },
                            close: { workspaceToClose = workspace.id },
                            delete: { workspaceToDelete = workspace.id }
                        )
                        .tabItem { Text(workspace.name) }
                        .tag(Optional(workspace.id))
                    }
                }
            }
        }
        .disabled(store.loadBlocked)
        .safeAreaInset(edge: .top) {
            if let error = store.persistenceError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).foregroundStyle(.red)
                    HStack {
                        Button("Retry") { store.retryPersistence() }
                        if store.loadBlocked {
                            Button("Back Up and Start Fresh") { store.backUpAndStartFresh() }
                        }
                        Button("Show Workspace File") {
                            NSWorkspace.shared.activateFileViewerSelecting([store.storageURL])
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
            }
        }
        .onAppear {
            selectedWorkspaceID = selectedWorkspaceID ?? store.openWorkspaces.first?.id
        }
        .onReceive(NotificationCenter.default.publisher(for: .createWorkspace)) { _ in
            createWorkspace()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 7) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    Text("MultiTerminal")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize()
                }
                .padding(.horizontal, 10)
                .accessibilityElement(children: .combine)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: createWorkspace) {
                    Label("New Workspace", systemImage: "plus.rectangle.on.rectangle")
                }

                Menu {
                    if store.closedWorkspaces.isEmpty {
                        Text("No closed workspaces")
                    } else {
                        ForEach(store.closedWorkspaces) { workspace in
                            Button(workspace.name) {
                                store.openWorkspace(id: workspace.id)
                                selectedWorkspaceID = workspace.id
                            }
                        }
                    }
                } label: {
                    Label("Open Workspace", systemImage: "rectangle.badge.plus")
                }

                Menu {
                    Text("Global terminal theme")
                    Divider()
                    ForEach(TerminalTheme.allCases) { theme in
                        Button {
                            store.setGlobalTheme(theme)
                        } label: {
                            ThemeMenuLabel(title: theme.displayName, selected: store.globalTheme == theme)
                        }
                    }
                } label: {
                    Label("Terminal Theme", systemImage: "paintpalette")
                }

                if let selectedWorkspaceID, store.workspace(id: selectedWorkspaceID) != nil {
                    PaneTypeMenu(workspaceID: selectedWorkspaceID)

                    Menu {
                        Button("Rename Workspace") {
                            workspaceToRename = store.workspace(id: selectedWorkspaceID)
                        }
                        Button("Close Workspace") {
                            workspaceToClose = selectedWorkspaceID
                        }
                        Divider()
                        Button("Delete Workspace", role: .destructive) {
                            workspaceToDelete = selectedWorkspaceID
                        }
                    } label: {
                        Label("Workspace Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(item: $workspaceToRename) { workspace in
            RenameWorkspaceSheet(workspace: workspace) { name in
                store.renameWorkspace(id: workspace.id, name: name)
            }
        }
        .alert("Close workspace?", isPresented: isPresentingCloseAlert) {
            Button("Close", role: .destructive) {
                guard let id = workspaceToClose, let workspace = store.workspace(id: id) else { return }
                sessions.terminateWorkspace(workspace)
                store.closeWorkspace(id: id)
                contents.closeWorkspace(id)
                selectedWorkspaceID = store.openWorkspaces.first?.id
                workspaceToClose = nil
            }
            Button("Cancel", role: .cancel) { workspaceToClose = nil }
        } message: {
            Text(
                "Its terminal processes and previews will stop. The layout, files, and browser logins remain available to reopen."
            )
        }
        .alert("Delete workspace?", isPresented: isPresentingDeleteAlert) {
            Button("Delete", role: .destructive) {
                guard let id = workspaceToDelete, let workspace = store.workspace(id: id) else { return }
                sessions.terminateWorkspace(workspace)
                store.deleteWorkspace(id: id)
                contents.deleteWorkspace(id)
                selectedWorkspaceID = store.openWorkspaces.first?.id
                workspaceToDelete = nil
            }
            Button("Cancel", role: .cancel) { workspaceToDelete = nil }
        } message: {
            Text(
                "This removes the workspace configuration and its browser cookies and logins, and stops its terminal processes. Project files are kept."
            )
        }
        .alert(
            "Browser Data",
            isPresented: Binding(get: { contents.cleanupError != nil }, set: { if !$0 { contents.cleanupError = nil } })
        ) {
            Button("OK") { contents.cleanupError = nil }
        } message: { Text(contents.cleanupError ?? "") }
        .onDisappear { sessions.terminateAll(); contents.closeAll() }
    }

    private var isPresentingCloseAlert: Binding<Bool> {
        Binding(get: { workspaceToClose != nil }, set: { if !$0 { workspaceToClose = nil } })
    }

    private var isPresentingDeleteAlert: Binding<Bool> {
        Binding(get: { workspaceToDelete != nil }, set: { if !$0 { workspaceToDelete = nil } })
    }

    private func createWorkspace() {
        let workspace = store.createWorkspace()
        selectedWorkspaceID = workspace.id
    }
}

private struct MultiTerminalWelcomeView: View {
    let createWorkspace: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("MultiTerminal")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Terminals, files, and browsers. One workspace.")
                .foregroundStyle(.secondary)
            Button("Create Workspace", action: createWorkspace)
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RenameWorkspaceSheet: View {
    let workspace: Workspace
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(workspace: Workspace, save: @escaping (String) -> Void) {
        self.workspace = workspace
        self.save = save
        _name = State(initialValue: workspace.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Workspace").font(.headline)
            AutofocusedTextField(
                text: $name,
                placeholder: "Workspace name",
                onSubmit: commit
            )
            .frame(height: 24)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func commit() {
        save(name)
        dismiss()
    }
}

/// A native text field is deliberately focused only after it joins the sheet's
/// window. This avoids the timing race where SwiftUI focus can remain on the
/// terminal that opened the sheet.
private struct AutofocusedTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        focusWhenAttached(field, remainingAttempts: 3)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    private func focusWhenAttached(_ field: NSTextField, remainingAttempts: Int) {
        DispatchQueue.main.async {
            guard let window = field.window else {
                if remainingAttempts > 0 {
                    focusWhenAttached(field, remainingAttempts: remainingAttempts - 1)
                }
                return
            }
            window.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>
        private let onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }
            onSubmit()
            return true
        }
    }
}

private struct WorkspaceView: View {
    let workspace: Workspace
    let rename: () -> Void
    let close: () -> Void
    let delete: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(workspace.name)
                    .font(.headline)
                    .foregroundStyle(colorScheme == .light ? Color.black : Color.primary)
                Text("Drag tabs to split or group · drag dividers to resize")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Rename", action: rename)
                Button("Close", action: close)
                Menu {
                    Button("Delete Workspace", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            Divider()
            WorkspaceGridView(workspace: workspace)
        }
    }
}

private struct WorkspaceGridView: View {
    let workspace: Workspace
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var sessions: TerminalSessionRegistry
    @EnvironmentObject private var contents: PaneContentRegistry

    var body: some View {
        WorkspaceLayoutView(workspace: workspace, store: store, sessions: sessions, contents: contents)
            .padding(8)
    }
}

struct TerminalPaneView: View {
    let workspaceID: UUID
    let pane: TerminalPane
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var sessions: TerminalSessionRegistry

    @State private var selectedFolderURL: URL?
    @State private var showFolderChoice = false
    @State private var launcherError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                Text(pane.directoryPath)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Menu {
                    Menu("Open In") {
                        Button("Finder", action: openInFinder)
                        Button("Visual Studio Code", action: openInVSCode)
                    }
                    Menu("Theme") {
                        Button {
                            store.setThemeOverride(nil, for: pane.id, in: workspaceID)
                        } label: {
                            ThemeMenuLabel(
                                title: "Use Global (\(store.globalTheme.displayName))",
                                selected: pane.themeOverride == nil
                            )
                        }
                        Divider()
                        ForEach(TerminalTheme.allCases) { theme in
                            Button {
                                store.setThemeOverride(theme, for: pane.id, in: workspaceID)
                            } label: {
                                ThemeMenuLabel(title: theme.displayName, selected: pane.themeOverride == theme)
                            }
                        }
                    }
                    Button("Set Default Folder…", action: chooseFolder)
                    Divider()
                    Button("Close Terminal", role: .destructive, action: closeTerminal)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(.bar)
            Divider()
            TerminalHostView(pane: pane)
        }
        .confirmationDialog("Use this folder", isPresented: $showFolderChoice, titleVisibility: .visible) {
            #if !APP_STORE
                Button("Change Shell Now and Save") { applyFolder(changeShellNow: true) }
            #endif
            Button("Save for Next Launch") { applyFolder(changeShellNow: false) }
            Button("Cancel", role: .cancel) { selectedFolderURL = nil }
        } message: {
            #if APP_STORE
                Text(
                    "\(selectedFolderURL?.path ?? "")\nClose and reopen this workspace to start new shells with access to this folder."
                )
            #else
                Text(selectedFolderURL?.path ?? "")
            #endif
        }
        .alert("Unable to Open Folder", isPresented: isPresentingLauncherError) {
            Button("OK", role: .cancel) { launcherError = nil }
        } message: {
            Text(launcherError ?? "")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: pane.directoryPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedFolderURL = url.standardizedFileURL
        showFolderChoice = true
    }

    private func applyFolder(changeShellNow: Bool) {
        guard let selectedFolderURL else { return }
        let path = selectedFolderURL.path
        do {
            let bookmark = try DirectoryAccess.bookmark(for: selectedFolderURL)
            store.setDirectory(path, bookmark: bookmark, for: pane.id, in: workspaceID)
        } catch {
            launcherError =
                "The folder permission could not be saved. Choose the folder again. \(error.localizedDescription)"
            return
        }
        if changeShellNow {
            sessions.changeDirectoryNow(path, for: pane.id)
        }
        self.selectedFolderURL = nil
    }

    private func closeTerminal() {
        sessions.terminate(paneID: pane.id)
        store.removePane(id: pane.id, from: workspaceID)
    }

    private var isPresentingLauncherError: Binding<Bool> {
        Binding(get: { launcherError != nil }, set: { if !$0 { launcherError = nil } })
    }

    private func openInFinder() {
        launcherError = FolderLauncher.openInFinder(directoryPath: pane.directoryPath)
    }

    private func openInVSCode() {
        FolderLauncher.openInVSCode(directoryPath: pane.directoryPath) { error in
            DispatchQueue.main.async {
                launcherError = error
            }
        }
    }
}

private struct ThemeMenuLabel: View {
    let title: String
    let selected: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }
}
