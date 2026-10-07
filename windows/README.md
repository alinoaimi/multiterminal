# MultiTerminal for Windows

Native Windows Forms app for Windows 11 x64, using ConPTY, VtNetCore and
Microsoft Edge WebView2. Requires the .NET 10 SDK to build. Browser and preview
panes require the separately installed Microsoft Edge WebView2 Runtime.

## Build and run

From the repository root on Windows:

```powershell
dotnet restore windows/App/MultiTerminal.csproj --locked-mode -r win-x64
dotnet build windows/App/MultiTerminal.csproj -c Release -r win-x64 --no-restore
dotnet run --project windows/App/MultiTerminal.csproj -c Release -r win-x64 --no-restore
```

The project can also be cross-compiled on Linux with the .NET 10 SDK, but its
GUI, ConPTY and WebView2 integration must run on Windows. Windows PowerShell is
the default shell; PowerShell 7, WSL and other command-line tools are installed separately.

## Tests

Core model and terminal-parser checks can run on any platform with the .NET 10 SDK:

```sh
dotnet run --project windows/Tests/MultiTerminal.Tests.csproj -c Release
```

Run the native checks on Windows with WebView2 Runtime installed:

```powershell
$report = Join-Path $env:TEMP 'multiterminal-source-validation.json'
dotnet run --project windows/App/MultiTerminal.csproj -c Release -r win-x64 --no-restore -- --self-test $report
if ($LASTEXITCODE -ne 0) { throw 'Windows integration checks failed' }
Get-Content $report
```

The self-test uses isolated temporary settings/profiles, native ConPTY and WebView2,
and a loopback HTTP server. It writes a JSON report and terminal screenshot.

## Local data

Source builds save settings to `%LOCALAPPDATA%\MultiTerminal Source\workspaces.json`
and browser profiles under the same root, separate from the closed-source app.
The app has no telemetry or automatic updater. Microsoft manages updates to the
separate WebView2 Runtime. Shells run with your Windows user's permissions.

## License and distribution

[AGPL-3.0-only](../LICENSE). Dependency notices are in [Licenses/](Licenses/) and
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). Building copies the project license,
README and dependency notices beside the application. NuGet restores dependencies
using their checked-in lock files.

This repository contains source, not an installer or signing credentials. If you
later distribute self-contained binaries, include the .NET runtime and Windows
Desktop runtime licenses and third-party notices from the exact runtime packages
you distribute, as well as the app and dependency notices.
