// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MultiTerminal",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MultiTerminal", targets: ["MultiTerminal"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
    ],
    targets: [
        .executableTarget(
            name: "MultiTerminal",
            dependencies: [
                "SwiftTerm",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MultiTerminalTests",
            dependencies: ["MultiTerminal"]
        ),
    ]
)
