import Foundation

enum AppDocumentation {
    static func documentURL(named name: String, in app: Bundle = .main) -> URL? {
        resourceURL(named: name, extension: "html", in: app)
    }

    static func resourceURL(named name: String, extension fileExtension: String, in app: Bundle = .main) -> URL? {
        // Support both app bundles and the executable produced by SwiftPM.
        if let direct = app.url(forResource: name, withExtension: fileExtension) { return direct }
        if let resourceURL = app.url(forResource: "MultiTerminal_MultiTerminal", withExtension: "bundle"),
           let resources = Bundle(url: resourceURL),
           let document = resources.url(forResource: name, withExtension: fileExtension) { return document }
        #if SWIFT_PACKAGE
            // Only the unbundled SwiftPM executable needs its generated build-tree lookup.
            if app.bundleURL.pathExtension != "app" {
                return Bundle.module.url(forResource: name, withExtension: fileExtension)
            }
        #endif
        return nil
    }
}
