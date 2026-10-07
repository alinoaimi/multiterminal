import Foundation
@testable import MultiTerminal
import XCTest

final class AppDocumentationTests: XCTestCase {
    func testPackagedHelpDoesNotDependOnTheDeveloperBuildDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("MultiTerminal.app")
        let resources = appURL.appendingPathComponent("Contents/Resources")
        let nested = resources.appendingPathComponent("MultiTerminal_MultiTerminal.bundle")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "test.multiterminal.help", "CFBundlePackageType": "APPL"],
            format: .xml,
            options: 0
        )
        try info.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        try "Help".write(to: nested.appendingPathComponent("Help.html"), atomically: true, encoding: .utf8)
        try "Privacy".write(to: resources.appendingPathComponent("Privacy.html"), atomically: true, encoding: .utf8)
        let app = try XCTUnwrap(Bundle(url: appURL))
        XCTAssertEqual(
            AppDocumentation.documentURL(named: "Help", in: app)?.standardizedFileURL,
            nested.appendingPathComponent("Help.html").standardizedFileURL
        )
        XCTAssertEqual(
            AppDocumentation.documentURL(named: "Privacy", in: app)?.standardizedFileURL,
            resources.appendingPathComponent("Privacy.html").standardizedFileURL
        )
        XCTAssertNil(AppDocumentation.documentURL(named: "Missing", in: app))
    }

    func testSwiftPMHelpResourcesAreAvailable() throws {
        for name in ["Help", "Privacy"] {
            let url = try XCTUnwrap(AppDocumentation.documentURL(named: name))
            XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("MultiTerminal"))
        }
    }

    func testSwiftPMLicenseResourcesAreAvailable() throws {
        for (name, fileExtension, expected) in [
            ("LICENSE", "txt", "AGPL-3.0-only"),
            ("THIRD_PARTY_NOTICES", "md", "SwiftTerm"),
        ] {
            let url = try XCTUnwrap(AppDocumentation.resourceURL(named: name, extension: fileExtension))
            XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains(expected))
        }
    }
}
