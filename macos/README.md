# MultiTerminal for macOS

A native macOS workspace for terminals, embedded browsers, and live file previews.

## Build and run

Requires macOS 14 or later and a Swift 6 toolchain (Xcode 16 or later).
From the repository root:

```sh
cd macos
swift build
swift run MultiTerminal
swift test
```

Open `macos/Package.swift` in Xcode to develop the app. Swift Package Manager
downloads SwiftTerm, Swift Markdown, and their dependencies when building.
`Package.resolved` records dependency versions. App code and bundled resources
are in `Sources/`; tests are in `Tests/`.

## Local data and permissions

Workspace layouts are stored locally in
`~/Library/Application Support/MultiTerminal Source/workspaces.json`.
Browser panes and commands you run can access the network. Terminal sessions
run with your macOS user's permissions; saved layouts do not resume commands.
The app has no automatic updater or telemetry.

## License resources

The repository's [LICENSE](../LICENSE) and
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) apply to this implementation.
Their bundled copies in `Sources/MultiTerminal/Resources/` must stay in sync
with the root files so the app's Help menu displays the same notices.
