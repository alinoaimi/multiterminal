import AppKit
import WebKit

enum BrowserAddress {
    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let lower = text.lowercased()
        let value: String
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { value = text }
        else if text.contains("://") { return nil }
        else {
            let isLocal = lower == "localhost" || lower.hasPrefix("localhost:") || lower.hasPrefix("localhost/")
                || lower.hasPrefix("127.") || lower.hasPrefix("[::1]")
            value = (isLocal ? "http://" : "https://") + text
        }
        guard let url = URL(string: value), let host = url.host, !host.isEmpty,
              url.scheme == "http" || url.scheme == "https", url.user == nil, url.password == nil else { return nil }
        return url
    }
}

final class BrowserPaneView: NSView, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    private(set) var webView: WKWebView!
    var urlChanged: ((String) -> Void)?
    var openTab: ((URL) -> Void)?
    private let address = NSTextField()
    private let status = NSTextField(labelWithString: "Enter a URL to start browsing")
    private let bar = NSStackView()
    private var observations: [NSKeyValueObservation] = []
    private var backButton: ActionButton!
    private var forwardButton: ActionButton!
    private var reloadButton: ActionButton!
    private var needsAddressFocus: Bool
    private var isClosed = false

    init(pane: BrowserPane, dataStore: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        webView = WKWebView(frame: .zero, configuration: configuration)
        needsAddressFocus = pane.url.isEmpty
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        webView.navigationDelegate = self
        webView.uiDelegate = self
        address.placeholderString = "URL or localhost:3000"
        address.stringValue = pane.url
        address.delegate = self
        address.target = self
        address.action = #selector(navigate)
        address.setAccessibilityLabel("Browser address")
        backButton = ActionButton("Back", symbol: "chevron.left") { [weak self] in self?.webView?.goBack() }
        forwardButton = ActionButton("Forward", symbol: "chevron.right") { [weak self] in self?.webView?.goForward() }
        reloadButton = ActionButton("Reload", symbol: "arrow.clockwise") { [weak self] in
            guard let self, !isClosed else { return }
            if webView.isLoading { webView.stopLoading() }
            else if webView.url != nil { webView.reload() } else { navigate() }
        }
        let external = ActionButton("Open in Default Browser", symbol: "arrow.up.forward.square") { [weak self] in
            if let url = self?.webView?.url { NSWorkspace.shared.open(url) }
        }
        bar.orientation = .horizontal; bar.spacing = 8
        [backButton!, forwardButton!, reloadButton!, address, external].forEach { bar.addArrangedSubview($0) }
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status
            .lineBreakMode = .byTruncatingTail
        [bar, webView, status].forEach { addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 6), bar.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 8
            ),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bar.heightAnchor.constraint(equalToConstant: 26),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3), status.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 8
            ),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            status.heightAnchor.constraint(equalToConstant: 16),
            webView.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor), webView.bottomAnchor.constraint(
                equalTo: status.topAnchor,
                constant: -3
            ),
        ])
        observations = [
            webView
                .observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in
                    self?.updateControls()
                } },
            webView
                .observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor in
                    self?.updateControls()
                } },
            webView
                .observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in
                    self?.updateControls()
                } },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in
                if self?.webView?.isLoading == false { self?.committedURLChanged() }
            } },
        ]
        updateControls()
        if let url = BrowserAddress.url(from: pane.url) { webView.load(URLRequest(url: url)) }
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if needsAddressFocus, window != nil {
            needsAddressFocus = false
            DispatchQueue.main
                .async { [weak self] in guard let self else { return }; window?.makeFirstResponder(address) }
        }
    }

    @objc private func navigate() {
        guard !isClosed else { return }
        guard let url = BrowserAddress.url(from: address.stringValue)
        else { status.stringValue = "Enter a valid HTTP or HTTPS address."; return }
        webView.load(URLRequest(url: url)); window?.makeFirstResponder(webView)
    }

    private func updateControls() {
        guard !isClosed else { return }
        backButton.isEnabled = webView.canGoBack; forwardButton.isEnabled = webView.canGoForward
        reloadButton.image = NSImage(
            systemSymbolName: webView.isLoading ? "xmark" : "arrow.clockwise",
            accessibilityDescription: webView.isLoading ? "Stop" : "Reload"
        )
        if webView.isLoading { status.stringValue = "Loading…" }
    }

    private func committedURLChanged() {
        guard !isClosed, let url = webView.url, ["http", "https"].contains(url.scheme ?? "") else { return }
        if address.currentEditor() == nil { address.stringValue = url.absoluteString }
        urlChanged?(url.absoluteString)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { committedURLChanged() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        committedURLChanged(); status.stringValue = webView.title ?? "Loaded"; updateControls()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        show(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { show(error) }
    private func show(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        status.stringValue = error.localizedDescription; updateControls()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void)
    {
        guard let url = action.request.url, ["http", "https", "about"].contains(url.scheme ?? "") else {
            status.stringValue = "Use Open in Default Browser for this link."; decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView?
    {
        if let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") { openTab?(url) }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void)
    {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void)
    {
        let alert = NSAlert(); alert.messageText = frame.request.url?.host ?? "Website"; alert.informativeText = message
        alert.runModal(); completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void)
    {
        let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle: "OK"); alert
            .addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void)
    {
        let alert = NSAlert(); alert.messageText = prompt; alert.addButton(withTitle: "OK"); alert
            .addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? ""); field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true; observations.removeAll(); webView.stopLoading(); webView.navigationDelegate = nil; webView
            .uiDelegate = nil
        webView.removeFromSuperview(); webView = nil; urlChanged = nil; openTab = nil
    }
}
