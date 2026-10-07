import AppKit
import PDFKit
import Quartz
import WebKit

final class FilePreviewView: NSView, WKNavigationDelegate {
    private(set) var pane: FilePreviewPane
    private let save: (FilePreviewPane) -> Void
    var openLink: ((URL) -> Void)?
    private var access: FileAccess?
    private var assetAccess: FileAccess?
    private var watcher: PreviewFileWatcher?
    private var format: PreviewFormat?
    private var content: NSView?
    private let container = NSView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var webView: WKWebView?
    private var markdownHandler: MarkdownResourceHandler?
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var scrollPosition: [Double]?
    private var closed = false
    private(set) var lastError: String?
    var renderedContent: NSView? { content }

    init(pane: FilePreviewPane, update: @escaping (FilePreviewPane) -> Void) {
        self.pane = pane; save = update
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let bar = NSStackView()
        bar.spacing = 10; bar.orientation = .horizontal
        bar.addArrangedSubview(ActionButton("Reload", symbol: "arrow.clockwise") { [weak self] in self?.reload() })
        bar.addArrangedSubview(ActionButton("Choose Another File…", symbol: "doc.badge.plus") { [weak self] in
            guard let self, let file = PaneCreation.chooseFile(id: pane.id) else { return }; save(file)
        })
        bar
            .addArrangedSubview(ActionButton("Allow Asset Folder…", symbol: "folder.badge.plus") { [weak self] in
                self?.chooseAssetFolder()
            })
        let label = NSTextField(labelWithString: "Read-only preview"); label.font = .systemFont(ofSize: 11); label
            .textColor = .secondaryLabelColor
        bar.addArrangedSubview(label)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 2
        [bar, container, status].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), bar.topAnchor.constraint(
                equalTo: topAnchor,
                constant: 6
            ),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            bar.heightAnchor.constraint(equalToConstant: 24),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), status.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -8
            ),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            status.heightAnchor.constraint(equalToConstant: 30),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6), container.bottomAnchor.constraint(
                equalTo: status.topAnchor,
                constant: -4
            ),
        ])
        establishAccess()
    }

    required init?(coder: NSCoder) { nil }

    func update(_ newPane: FilePreviewPane) {
        guard pane != newPane else { return }
        pane = newPane; establishAccess()
    }

    private func establishAccess() {
        generation += 1; loadTask?.cancel()
        watcher?.close(); watcher = nil; access = nil; assetAccess = nil
        do {
            access = try FileAccess(path: pane.path, bookmark: pane.bookmark)
            if let path = pane.assetDirectoryPath { assetAccess = try FileAccess(
                path: path,
                bookmark: pane.assetDirectoryBookmark
            ) }
            guard let access else { return }
            var refreshedPane = pane
            refreshedPane.path = access.url.path
            if let refreshed = access.refreshedBookmark { refreshedPane.bookmark = refreshed }
            if let assetAccess {
                refreshedPane.assetDirectoryPath = assetAccess.url.path
                if let refreshed = assetAccess.refreshedBookmark { refreshedPane.assetDirectoryBookmark = refreshed }
            }
            if refreshedPane != pane {
                pane = refreshedPane
                let savedPane = refreshedPane
                DispatchQueue.main.async { [weak self] in
                    guard let self, !closed, pane == savedPane else { return }
                    save(savedPane)
                }
            }
            watcher = PreviewFileWatcher(url: access.url) { [weak self] in self?.reload() }
            reload()
        } catch { showError("File access has expired. Choose the file again. \(error.localizedDescription)") }
    }

    private func chooseAssetFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.directoryURL = access?.url.deletingLastPathComponent(); panel
            .title = "Allow access to this preview's assets"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let file = access?.url,
              file.resolvingSymlinksInPath().path.hasPrefix(url.resolvingSymlinksInPath().path + "/")
        else {
            showError("Choose the folder containing this file, or one of its parent folders."); return
        }
        do {
            var updated = pane; updated.assetDirectoryPath = url.path; updated.assetDirectoryBookmark = try FileAccess
                .bookmark(for: url); save(updated)
        } catch { showError(error.localizedDescription) }
    }

    func reload() {
        guard !closed, let access else { return }
        generation += 1; let currentGeneration = generation
        loadTask?.cancel()
        let url = access.url
        let nextFormat = PreviewFormat.detect(url)
        loadTask = Task { [weak self] in
            do {
                let result: (Data?, String?) = try await Task.detached(priority: .userInitiated) {
                    guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
                    switch nextFormat {
                    case .text, .markdown:
                        let size = try (url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                        guard size <= 10 * 1024 * 1024 else { throw PreviewError.tooLarge }
                        let data = try Data(contentsOf: url)
                        let text: String
                        if let decoded = String(data: data, encoding: .utf8) { text = decoded }
                        else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
                                let decoded = String(
                                    data: data,
                                    encoding: .utf16
                                ) { text = decoded }
                        else { throw PreviewError.encoding }
                        return (nil, nextFormat == .markdown ? MarkdownPreviewRenderer.html(text) : text)
                    case .image: return try (Data(contentsOf: url), nil)
                    default: return (nil, nil)
                    }
                }.value
                guard let self, !Task.isCancelled, !closed, generation == currentGeneration else { return }
                lastError = nil
                present(nextFormat, data: result.0, text: result.1, url: url)
                if lastError == nil { status.stringValue = url.path }
            } catch {
                guard let self, !Task.isCancelled, !closed, generation == currentGeneration else { return }
                showError("\(error.localizedDescription) Use Reload or Choose Another File.")
            }
        }
    }

    private func present(_ next: PreviewFormat, data: Data?, text: String?, url: URL) {
        if format != next { clearContent(); format = next }
        container.isHidden = false
        switch next {
        case .image:
            let view = content as? NSImageView ?? NSImageView()
            view.imageScaling = .scaleProportionallyUpOrDown; view.imageAlignment = .alignCenter
            view.image = data.flatMap(NSImage.init(data:)); install(view)
            if view.image == nil { showError("This image could not be decoded.") }
        case .pdf:
            let view = content as? PDFView ?? PDFView()
            let index = view.currentPage.flatMap { view.document?.index(for: $0) } ?? 0
            let scale = view.scaleFactor
            view.document = PDFDocument(url: url)
            if view.document?
                .isLocked ==
                true { showError("This PDF is password protected. Open it in Preview to unlock it."); return }
            view.autoScales = true; view.displayMode = .singlePageContinuous
            if let document = view.document, document.pageCount > 0, let page = document.page(at: min(
                index,
                document.pageCount - 1
            )) { view.go(to: page) }
            if content != nil, scale > 0 { view.scaleFactor = scale }
            install(view)
            if view.document == nil { showError("This PDF could not be opened.") }
        case .text:
            let scroll = content as? NSScrollView ?? NSScrollView()
            let view = scroll.documentView as? NSTextView ?? NSTextView()
            let origin = scroll.contentView.bounds.origin
            view.isEditable = false; view.isSelectable = true; view.font = .monospacedSystemFont(
                ofSize: 13,
                weight: .regular
            )
            view.isRichText = false; view.string = text ?? ""; view.isVerticallyResizable = true
            view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
            view.textContainerInset = NSSize(width: 12, height: 12)
            scroll.hasVerticalScroller = true; scroll.documentView = view; install(scroll)
            view.frame.size.width = scroll.contentSize.width
            scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
        case .html, .markdown:
            let root = assetAccess?.url ?? url.deletingLastPathComponent()
            if webView == nil {
                let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
                configuration.defaultWebpagePreferences.allowsContentJavaScript = next == .html
                if next == .markdown {
                    let handler = MarkdownResourceHandler(rootURL: root, documentURL: url)
                    markdownHandler = handler; configuration.setURLSchemeHandler(
                        handler,
                        forURLScheme: "multiterminal-preview"
                    )
                }
                webView = WKWebView(frame: .zero, configuration: configuration); webView?.navigationDelegate = self
            }
            guard let webView else { return }; install(webView)
            let capturedGeneration = generation
            webView.evaluateJavaScript("[window.scrollX,window.scrollY]") { [weak self] position, _ in
                guard let self, !closed, generation == capturedGeneration else { return }
                scrollPosition = position as? [Double]
                if next == .markdown {
                    markdownHandler?.rootURL = root; markdownHandler?.documentURL = url; markdownHandler?
                        .html = text ?? ""
                    if let request = markdownHandler?.requestURL { webView.load(URLRequest(
                        url: request,
                        cachePolicy: .reloadIgnoringLocalCacheData
                    )) }
                } else { webView.loadFileURL(url, allowingReadAccessTo: root) }
            }
        case .quickLook:
            if let view = content as? QLPreviewView { view.previewItem = url as NSURL; view.refreshPreviewItem() }
            else if let view = QLPreviewView(frame: container.bounds, style: .normal) {
                view.shouldCloseWithWindow = false; view.autostarts = false; view
                    .previewItem = url as NSURL; install(view)
            } else { showError("No preview is available for this file type.") }
        }
    }

    private func install(_ view: NSView) {
        guard content !== view else { return }
        content?.removeFromSuperview(); content = view
        view.frame = container.bounds; view.autoresizingMask = [.width, .height]; container.addSubview(view)
    }

    private func showError(_ text: String) { lastError = text; status.stringValue = text; container.isHidden = true }
    private func clearContent() {
        (content as? QLPreviewView)?.close(); webView?.stopLoading(); webView?.navigationDelegate = nil
        content?.removeFromSuperview(); content = nil; webView = nil; markdownHandler = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let position = scrollPosition, position.count == 2 {
            webView.evaluateJavaScript("window.scrollTo(\(position[0]),\(position[1]))", completionHandler: nil)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError)
            .code !=
            NSURLErrorCancelled { showError("\(error.localizedDescription) For linked files, use Allow Asset Folder.") }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if action.navigationType == .linkActivated, let url = action.request.url,
           ["http", "https"].contains(url.scheme ?? "")
        {
            openLink?(url); decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }

    func close() {
        closed = true; loadTask?.cancel(); loadTask = nil; watcher?.close(); watcher = nil
        clearContent(); access = nil; assetAccess = nil; openLink = nil
    }
}

private enum PreviewError: LocalizedError {
    case tooLarge, encoding
    var errorDescription: String? {
        switch self {
        case .tooLarge: "Text previews are limited to 10 MB. Open this file in an external editor."
        case .encoding: "This file is not readable UTF-8 or UTF-16 text."
        }
    }
}
