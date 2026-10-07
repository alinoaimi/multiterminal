import AppKit
@testable import MultiTerminal
import PDFKit
import WebKit
import XCTest

final class PanePreviewTests: XCTestCase {
    @MainActor private func eventually(_ condition: @escaping () async -> Bool) async -> Bool {
        for _ in 0 ..< 80 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @MainActor func testNativePreviewsRenderAndRecoverFromMissingFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus(); NSColor.red.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 32, height: 32))
            .fill(); image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let imageURL = directory.appendingPathComponent("test.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: imageURL)
        let pdfURL = directory.appendingPathComponent("test.pdf"), pdf = PDFDocument()
        pdf.insert(PDFPage(image: image)!, at: 0); XCTAssertTrue(pdf.write(to: pdfURL))
        let textURL = directory.appendingPathComponent("test.txt")
        try Data("First version".utf8).write(to: textURL)
        let preview = FilePreviewView(pane: FilePreviewPane(path: imageURL.path), update: { _ in })
        defer { preview.close() }
        let imageLoaded = await eventually { (preview.renderedContent as? NSImageView)?.image != nil }
        XCTAssertTrue(imageLoaded); XCTAssertNil(preview.lastError)
        preview.update(FilePreviewPane(id: preview.pane.id, path: pdfURL.path))
        let pdfLoaded = await eventually { (preview.renderedContent as? PDFView)?.document?.pageCount == 1 }
        XCTAssertTrue(pdfLoaded); XCTAssertNil(preview.lastError)
        preview.update(FilePreviewPane(id: preview.pane.id, path: textURL.path))
        let textLoaded = await eventually {
            ((preview.renderedContent as? NSScrollView)?.documentView as? NSTextView)?.string == "First version"
        }
        XCTAssertTrue(textLoaded)
        let original = preview.renderedContent
        try Data("Second version".utf8).write(to: textURL, options: .atomic)
        let reloaded = await eventually {
            ((preview.renderedContent as? NSScrollView)?.documentView as? NSTextView)?.string == "Second version"
        }
        XCTAssertTrue(reloaded); XCTAssertTrue(original === preview.renderedContent)
        try FileManager.default.removeItem(at: textURL)
        let missing = await eventually { preview.lastError != nil }; XCTAssertTrue(missing)
        try Data("Recovered".utf8).write(to: textURL)
        let recovered = await eventually {
            ((preview.renderedContent as? NSScrollView)?.documentView as? NSTextView)?.string == "Recovered" && preview
                .lastError == nil
        }
        XCTAssertTrue(recovered)
    }

    @MainActor func testMarkdownAndHTMLWebPreviewsRender() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let markdown = directory.appendingPathComponent("readme.md"),
            html = directory.appendingPathComponent("page.html")
        try Data("# Preview heading\n\n**Strong text**".utf8).write(to: markdown)
        try Data("<h1>HTML preview</h1><script>document.body.dataset.executed='yes'</script>".utf8).write(to: html)
        let preview = FilePreviewView(pane: FilePreviewPane(path: markdown.path), update: { _ in })
        defer { preview.close() }
        let markdownLoaded = await eventually {
            guard let web = preview.renderedContent as? WKWebView else { return false }
            return await (try? web.evaluateJavaScript("document.querySelector('h1')?.textContent")) as? String ==
                "Preview heading"
        }
        XCTAssertTrue(markdownLoaded, preview.lastError ?? "Markdown did not render")
        preview.update(FilePreviewPane(id: preview.pane.id, path: html.path))
        let htmlLoaded = await eventually {
            guard let web = preview.renderedContent as? WKWebView else { return false }
            return await (try? web.evaluateJavaScript("document.body.dataset.executed")) as? String == "yes"
        }
        XCTAssertTrue(htmlLoaded, preview.lastError ?? "HTML did not execute page script")
    }

    func testBrowserAddresses() {
        for input in ["localhost:5173/path", "127.0.0.1:8080", "[::1]:3000"] {
            XCTAssertEqual(BrowserAddress.url(from: input)?.scheme, "http")
        }
        XCTAssertEqual(BrowserAddress.url(from: "example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(BrowserAddress.url(from: "https://example.com/a?q=b")?.query, "q=b")
        for input in [
            "",
            "two words",
            "javascript:alert(1)",
            "file:///etc/passwd",
            "https://",
            "https://user:password@example.com",
        ] {
            XCTAssertNil(BrowserAddress.url(from: input), input)
        }
    }

    func testMarkdownBlocksImagesAndEscaping() {
        let html = MarkdownPreviewRenderer.html("""
        # Title
        - [x] Done
        - **Bold** and [link](https://example.com)

        ![alt](assets/image.png)

        | A | B |
        |---|---|
        | 1 | 2 |
        ```html
        <script>alert('x')</script>
        ```
        """)
        for expected in [
            "<h1>Title</h1>",
            "<table>",
            "<strong>Bold</strong>",
            "assets/image.png",
            "&lt;script&gt;",
            "disabled checked",
        ] {
            XCTAssertTrue(html.contains(expected), expected)
        }
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(MarkdownPreviewRenderer.html("[bad](javascript:alert%281%29)").contains("href=\"javascript:"))
    }

    func testPreviewDispatch() {
        for (path, format): (String, PreviewFormat) in [
            ("/tmp/a.md", .markdown),
            ("/tmp/a.HTML", .html),
            ("/tmp/a.pdf", .pdf),
            ("/tmp/a.png", .image),
            ("/tmp/a.swift", .text),
            ("/tmp/a.zip", .quickLook),
        ] {
            XCTAssertEqual(PreviewFormat.detect(URL(fileURLWithPath: path)), format)
        }
    }

    @MainActor func testResourceHandlerConfinesRelativeAssets() {
        let handler = MarkdownResourceHandler(
            rootURL: URL(fileURLWithPath: "/tmp/project"),
            documentURL: URL(fileURLWithPath: "/tmp/project/docs/a.md")
        )
        XCTAssertEqual(handler.requestURL.path, "/docs/a.md")
        XCTAssertEqual(
            handler.localURL(URL(string: "multiterminal-preview://local/docs/image.png")!)?.lastPathComponent,
            "image.png"
        )
        XCTAssertNil(handler.localURL(URL(string: "multiterminal-preview://local/../../etc/passwd")!))
    }

    @MainActor func testFileWatcherSurvivesAtomicReplacementAndRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("test.txt")
        try Data("before".utf8).write(to: file)
        let changed = expectation(description: "Atomic replacement observed")
        var count = 0
        let watcher = PreviewFileWatcher(url: file) { count += 1; if count == 1 { changed.fulfill() } }
        defer { watcher.close() }
        try Data("after".utf8).write(to: file, options: .atomic)
        await fulfillment(of: [changed], timeout: 3)
        let second = expectation(description: "Replacement inode observed")
        let nextWatcher = PreviewFileWatcher(url: file) {
            if (try? String(contentsOf: file, encoding: .utf8)) == "recreated" { second.fulfill() }
        }
        defer { nextWatcher.close() }
        try FileManager.default.removeItem(at: file)
        try Data("recreated".utf8).write(to: file, options: .atomic)
        await fulfillment(of: [second], timeout: 3)
    }
}
