import Foundation

/// Keep user-selected folder access alive for the whole child-process lifetime.
/// New grants apply to newly spawned shells, not already-running children.
final class DirectoryAccess {
    let url: URL
    private var hasScope: Bool

    init(pane: TerminalPane) throws {
        #if APP_STORE
            if let bookmark = pane.directoryBookmark {
                var stale = false
                url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
                hasScope = url.startAccessingSecurityScopedResource()
                guard hasScope else { throw CocoaError(.fileReadNoPermission) }
            } else {
                url = URL(fileURLWithPath: pane.directoryPath, isDirectory: true)
                hasScope = false
            }
        #else
            url = URL(fileURLWithPath: pane.directoryPath, isDirectory: true)
            hasScope = false
        #endif
        // Restore a security-scoped grant before inspecting the directory.
        // Never silently replace an inaccessible project with the app container.
        do {
            try Self.validateDirectory(url)
        } catch {
            if hasScope {
                url.stopAccessingSecurityScopedResource()
                hasScope = false
            }
            throw error
        }
    }

    deinit {
        if hasScope { url.stopAccessingSecurityScopedResource() }
    }

    static func bookmark(for url: URL) throws -> Data? {
        #if APP_STORE
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            return try url.bookmarkData(options: .withSecurityScope,
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
            return nil
        #endif
    }

    static func validateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw CocoaError(.fileReadNoPermission)
        }
    }
}
