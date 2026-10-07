import Foundation

enum TerminalTheme: String, Codable, CaseIterable, Identifiable {
    case midnight
    case highContrast
    case amber

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .midnight: "Midnight"
        case .highContrast: "High Contrast"
        case .amber: "Amber"
        }
    }
}

struct TerminalPane: Codable, Identifiable, Equatable {
    let id: UUID
    var directoryPath: String
    var themeOverride: TerminalTheme?
    var directoryBookmark: Data?

    init(id: UUID = UUID(), directoryPath: String = NSHomeDirectory(), themeOverride: TerminalTheme? = nil) {
        self.id = id
        self.directoryPath = directoryPath
        self.themeOverride = themeOverride
    }
}

enum PaneKind: String, CaseIterable, Identifiable {
    case terminal, filePreview, browser
    var id: Self { self }
    var title: String {
        switch self { case .terminal: "Terminal"; case .filePreview: "File Preview"; case .browser: "Browser" }
    }

    var symbol: String {
        switch self { case .terminal: "terminal"; case .filePreview: "doc.richtext"; case .browser: "globe" }
    }
}

struct FilePreviewPane: Codable, Identifiable, Equatable {
    let id: UUID
    var path: String
    var bookmark: Data?
    var assetDirectoryPath: String?
    var assetDirectoryBookmark: Data?

    init(id: UUID = UUID(), path: String, bookmark: Data? = nil) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
    }
}

struct BrowserPane: Codable, Identifiable, Equatable {
    let id: UUID
    var url: String
    init(id: UUID = UUID(), url: String = "") { self.id = id; self.url = url }
}

enum WorkspacePane: Codable, Identifiable, Equatable {
    case terminal(TerminalPane)
    case filePreview(FilePreviewPane)
    case browser(BrowserPane)

    var id: UUID {
        switch self { case let .terminal(p): p.id; case let .filePreview(p): p.id; case let .browser(p): p.id }
    }

    var kind: PaneKind {
        switch self { case .terminal: .terminal; case .filePreview: .filePreview; case .browser: .browser }
    }

    var title: String {
        switch self {
        case let .terminal(p): URL(fileURLWithPath: p.directoryPath).lastPathComponent
        case let .filePreview(p): URL(fileURLWithPath: p.path).lastPathComponent
        case let .browser(p): URL(string: p.url)?.host ?? "Browser"
        }
    }

    // Terminal-only accessors keep folder controls and legacy callers type-safe.
    var terminal: TerminalPane? { if case let .terminal(p) = self { p } else { nil } }
    var directoryPath: String { terminal?.directoryPath ?? "" }
    var directoryBookmark: Data? { terminal?.directoryBookmark }
    var themeOverride: TerminalTheme? { terminal?.themeOverride }
}

struct Workspace: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var panes: [WorkspacePane]
    var layout: WorkspaceLayout?
    var focusedGroupID: UUID?

    init(id: UUID = UUID(), name: String, panes: [TerminalPane] = [TerminalPane()]) {
        self.id = id
        self.name = name
        self.panes = panes.map(WorkspacePane.terminal)
        layout = WorkspaceLayout.legacyGrid(paneIDs: panes.map(\.id))
        focusedGroupID = layout?.groups.first?.id
    }

    private enum CodingKeys: String, CodingKey { case id, name, panes, layout, focusedGroupID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        if let current = try? c.decode([WorkspacePane].self, forKey: .panes) {
            panes = current
        } else {
            panes = try c.decode([TerminalPane].self, forKey: .panes).map(WorkspacePane.terminal)
        }
        var seen = Set<UUID>()
        panes = panes.filter { seen.insert($0.id).inserted }
        layout = try? c.decodeIfPresent(WorkspaceLayout.self, forKey: .layout)
        if layout?.isValid(paneIDs: panes.map(\.id)) != true {
            layout = WorkspaceLayout.legacyGrid(paneIDs: panes.map(\.id))
        }
        focusedGroupID = try? c.decodeIfPresent(UUID.self, forKey: .focusedGroupID)
        if !((layout?.groups ?? []).contains { $0.id == focusedGroupID }) {
            focusedGroupID = layout?.groups.first?.id
        }
    }
}

struct PersistedWorkspaceState: Codable, Equatable {
    var schemaVersion: Int = 2
    var workspaces: [Workspace]
    var openWorkspaceIDs: [UUID]
    var globalTheme: TerminalTheme

    init(
        workspaces: [Workspace] = [],
        openWorkspaceIDs: [UUID] = [],
        globalTheme: TerminalTheme = .midnight
    ) {
        self.workspaces = workspaces
        self.openWorkspaceIDs = openWorkspaceIDs
        self.globalTheme = globalTheme
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case workspaces
        case openWorkspaceIDs
        case globalTheme
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1 ... 2).contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                                                   debugDescription: "This workspace file needs a different version of MultiTerminal.")
        }
        workspaces = try container.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        openWorkspaceIDs = try container.decodeIfPresent([UUID].self, forKey: .openWorkspaceIDs) ?? []
        globalTheme = try container.decodeIfPresent(TerminalTheme.self, forKey: .globalTheme) ?? .midnight
    }
}

enum ShellQuoting {
    static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
