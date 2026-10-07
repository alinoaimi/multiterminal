import AppKit
import Foundation

enum FolderLauncher {
    static func openInFinder(directoryPath: String) -> String? {
        let folderURL = validatedFolderURL(for: directoryPath)
        guard let folderURL else {
            return "The configured folder no longer exists. Choose a new default folder for this terminal."
        }
        guard NSWorkspace.shared.open(folderURL) else {
            return "Finder could not open \(folderURL.path)."
        }
        return nil
    }

    static func openInVSCode(directoryPath: String, completion: @escaping @Sendable (String?) -> Void) {
        guard let folderURL = validatedFolderURL(for: directoryPath) else {
            completion("The configured folder no longer exists. Choose a new default folder for this terminal.")
            return
        }
        guard let codeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else {
            completion("Visual Studio Code is not installed. Install it, then try again.")
            return
        }

        NSWorkspace.shared.open(
            [folderURL],
            withApplicationAt: codeURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            completion(error?.localizedDescription)
        }
    }

    private static func validatedFolderURL(for path: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
