import AppKit
import Markdown
import UniformTypeIdentifiers
import WebKit

final class FileAccess {
    let url: URL
    let refreshedBookmark: Data?
    private let scoped: Bool

    init(path: String, bookmark: Data?) throws {
        var stale = false
        if let bookmark {
            #if APP_STORE
                url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope, .withoutUI],
                    bookmarkDataIsStale: &stale
                )
            #else
                url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale)
            #endif
        } else { url = URL(fileURLWithPath: path) }
        scoped = url.startAccessingSecurityScopedResource()
        #if APP_STORE
            if bookmark != nil, !scoped { throw CocoaError(.fileReadNoPermission) }
        #endif
        refreshedBookmark = stale ? try? Self.bookmark(for: url) : nil
    }

    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }

    static func bookmark(for url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #if APP_STORE
            return try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        #else
            return try url.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        #endif
    }
}

/// Watch both the inode and its parent: editors commonly save by renaming a
/// replacement over the old inode. Reattach after each coalesced event.
@MainActor
final class PreviewFileWatcher {
    private let url: URL
    private let changed: () -> Void
    private nonisolated(unsafe) var sources: [DispatchSourceFileSystemObject] = []
    private var pending: Task<Void, Never>?
    private var closed = false
    private var fingerprint = ""
    init(url: URL, changed: @escaping () -> Void) {
        self.url = url; self.changed = changed; fingerprint = currentFingerprint(); attach()
    }

    private func currentFingerprint() -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "missing" }
        return [attributes[.systemFileNumber], attributes[.size], attributes[.modificationDate]]
            .map { String(describing: $0) }.joined(separator: ":")
    }

    private func attach() {
        sources.forEach { $0.cancel() }; sources.removeAll()
        for path in [url.path, url.deletingLastPathComponent().path] {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                                   eventMask: [
                                                                       .write,
                                                                       .delete,
                                                                       .rename,
                                                                       .extend,
                                                                       .attrib,
                                                                       .revoke,
                                                                   ], queue: .main)
            source.setEventHandler { [weak self] in Task { @MainActor in self?.schedule() } }
            source.setCancelHandler { Darwin.close(fd) }
            source.resume(); sources.append(source)
        }
    }

    private func schedule() {
        guard !closed else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, !closed else { return }
            attach()
            let next = currentFingerprint()
            if next != fingerprint { fingerprint = next; changed() }
        }
    }

    func close() {
        closed = true; pending?.cancel(); pending = nil; sources.forEach { $0.cancel() }; sources.removeAll()
    }

    deinit { sources.forEach { $0.cancel() } }
}

enum PreviewFormat: Equatable {
    case image, pdf, html, markdown, text, quickLook
    static func detect(_ url: URL) -> PreviewFormat {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "mdown"].contains(ext) { return .markdown }
        if ["html", "htm", "xhtml"].contains(ext) { return .html }
        if ext == "pdf" { return .pdf }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: ext)
        if type?.conforms(to: .image) == true { return .image }
        if type?.conforms(to: .text) == true || [
            "",
            "log",
            "json",
            "yaml",
            "yml",
            "toml",
            "env",
            "swift",
            "py",
            "js",
            "ts",
            "tsx",
            "jsx",
            "sh",
            "rs",
            "go",
            "c",
            "h",
            "cpp",
            "css",
            "sql",
        ].contains(ext) { return .text }
        return .quickLook
    }
}

enum MarkdownPreviewRenderer {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func html(_ source: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none'; frame-src 'none'; style-src 'unsafe-inline'; img-src multiterminal-preview: https: http: data:;">
        <style>body{font:15px/1.6 -apple-system,BlinkMacSystemFont,sans-serif;margin:24px;overflow-wrap:anywhere;color:light-dark(#20232a,#e4e7ef);background:light-dark(#fff,#17191e)}
        h1,h2,h3{line-height:1.25}a{color:light-dark(#0969da,#70b7ff)}pre,code{font-family:ui-monospace,monospace;font-size:.92em;background:light-dark(#f2f4f7,#252932);border-radius:5px}pre{padding:14px;overflow:auto}code{padding:2px 4px}pre code{padding:0}img{max-width:100%;height:auto}table{border-collapse:collapse;display:block;overflow:auto}td,th{border:1px solid #80808055;padding:7px 12px}blockquote{border-left:3px solid #80808066;margin-left:0;padding-left:16px;opacity:.85}hr{border:0;border-top:1px solid #80808055}</style>
        </head><body>\(render(Document(parsing: source)))</body></html>
        """
    }

    private static func render(_ node: any Markup) -> String {
        let children = { node.children.map { render($0) }.joined() }
        switch node {
        case let text as Markdown.Text: return escape(text.string)
        case let code as InlineCode: return "<code>\(escape(code.code))</code>"
        case let code as CodeBlock: return "<pre><code>\(escape(code.code))</code></pre>"
        case let heading as Heading: return "<h\(heading.level)>\(children())</h\(heading.level)>"
        case is Paragraph: return "<p>\(children())</p>"
        case is Strong: return "<strong>\(children())</strong>"
        case is Emphasis: return "<em>\(children())</em>"
        case is Strikethrough: return "<del>\(children())</del>"
        case is BlockQuote: return "<blockquote>\(children())</blockquote>"
        case is UnorderedList: return "<ul>\(children())</ul>"
        case let list as OrderedList: return "<ol start=\"\(list.startIndex)\">\(children())</ol>"
        case let item as ListItem:
            let box = item.checkbox
                .map { "<input type=\"checkbox\" disabled \($0 == .checked ? "checked" : "")> " } ?? ""
            return "<li>\(box)\(children())</li>"
        case let link as Markdown.Link:
            return "<a href=\"\(escape(safeDestination(link.destination)))\">\(children())</a>"
        case let image as Markdown.Image:
            return "<img src=\"\(escape(safeDestination(image.source)))\" alt=\"\(escape(image.plainText))\">"
        case is Table: return "<table>\(children())</table>"
        case is Table.Head: return "<thead><tr>\(children())</tr></thead>"
        case is Table.Body: return "<tbody>\(children())</tbody>"
        case is Table.Row: return "<tr>\(children())</tr>"
        case is Table.Cell: return "<td>\(children())</td>"
        case is ThematicBreak: return "<hr>"
        case is LineBreak: return "<br>"
        case is SoftBreak: return "\n"
        case let raw as HTMLBlock: return escape(raw.rawHTML)
        case let raw as InlineHTML: return escape(raw.rawHTML)
        default: return children()
        }
    }

    private static func safeDestination(_ destination: String?) -> String {
        guard let destination else { return "" }
        if let scheme = URL(string: destination)?.scheme,
           !["http", "https", "multiterminal-preview"].contains(scheme.lowercased()) { return "" }
        return destination
    }
}

/// Markdown is served from memory. Relative assets are confined to the chosen
/// directory, without writing generated HTML into the user's project.
final class MarkdownResourceHandler: NSObject, WKURLSchemeHandler {
    var rootURL: URL
    var documentURL: URL
    var html = ""
    init(rootURL: URL, documentURL: URL) { self.rootURL = rootURL; self.documentURL = documentURL }
    var requestURL: URL {
        var components = URLComponents(); components.scheme = "multiterminal-preview"; components.host = "local"
        components.path = String(documentURL.path.dropFirst(rootURL.path.count))
        if !components.path.hasPrefix("/") { components.path = "/" + components.path }
        return components.url!
    }

    func localURL(_ url: URL) -> URL? {
        let resolved = rootURL.appendingPathComponent(String(url.path.dropFirst())).standardizedFileURL
            .resolvingSymlinksInPath()
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        return resolved.path.hasPrefix(root + "/") ? resolved : nil
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url,
              let local = localURL(url) else { task.didFailWithError(CocoaError(.fileReadNoPermission)); return }
        do {
            let isDocument = local == documentURL.resolvingSymlinksInPath()
            let data = isDocument ? Data(html.utf8) : try Data(contentsOf: local)
            let mime = isDocument ? "text/html" : UTType(filenameExtension: local.pathExtension)?
                .preferredMIMEType ?? "application/octet-stream"
            task.didReceive(URLResponse(
                url: url,
                mimeType: mime,
                expectedContentLength: data.count,
                textEncodingName: isDocument ? "utf-8" : nil
            ))
            task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
