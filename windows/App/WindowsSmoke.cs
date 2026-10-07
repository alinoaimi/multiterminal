using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using MultiTerminal.Core;

namespace MultiTerminal;

/// <summary>Opt-in Windows integration checks, isolated from the user's data.</summary>
internal static class WindowsSmoke
{
    public static ConcurrentQueue<string> CallbackErrors { get; } = new();
    private static void Assert(bool condition, string message) { if (!condition) throw new Exception(message); }
    private static async Task Wait(Func<bool> condition, string message, int timeout = 30000)
    {
        var until = Environment.TickCount64 + timeout;
        while (Environment.TickCount64 < until)
        {
            if (!CallbackErrors.IsEmpty) throw new Exception(string.Join("\n", CallbackErrors));
            if (condition()) return;
            await Task.Delay(50);
        }
        Assert(condition(), message);
    }
    private static string Quote(string text) => "'" + text.Replace("'", "''") + "'";
    private static async Task WaitAsync(Func<Task<bool>> condition, string message)
    {
        var until = Environment.TickCount64 + 30000;
        while (Environment.TickCount64 < until)
        {
            if (!CallbackErrors.IsEmpty) throw new Exception(string.Join("\n", CallbackErrors));
            if (await condition()) return;
            await Task.Delay(100);
        }
        throw new Exception(message);
    }
    private static void Send(TerminalPaneView pane, string command) => pane.Terminal.Session!.Send(Encoding.UTF8.GetBytes(command + "\r"));
    private static async Task<string?> JavaScript(BrowserPaneView pane, string expression) => JsonSerializer.Deserialize<string>(await pane.Web.CoreWebView2.ExecuteScriptAsync(expression));
    private static bool Alive(int id)
    { try { using var process = Process.GetProcessById(id); return !process.HasExited; } catch (ArgumentException) { return false; } }

    public static async Task Run(MainForm window, string outputPath)
    {
        var results = new List<string>(); var passed = false; string? error = null;
        Process? unrelated = null;
        outputPath = Path.GetFullPath(outputPath); Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
        using var server = new FixtureServer();
        try
        {
            window.ErrorHandler = message => throw new Exception(message);
            window.Confirmation = (_, _) => true;
            var wsid = window.Active!;
            var first = window.Views.Values.OfType<TerminalPaneView>().First();
            await Wait(() => first.Terminal.Session?.ProcessId > 0, "PowerShell did not start.");
            var folder = Path.Combine(AppPaths.Root, "a project's folder μ"); Directory.CreateDirectory(folder);
            window.Store.Edit(wsid, w => w.Panes[0].DirectoryPath = folder); first.Restart();
            await Wait(() => first.Terminal.Session?.ProcessId > 0 && first.Terminal.IsRunning, "PowerShell did not restart.");
            var cwdFile = Path.Combine(AppPaths.Root, "cwd.txt");
            Send(first, $"[IO.File]::WriteAllText({Quote(cwdFile)}, (Get-Location).Path)");
            await Wait(() => File.Exists(cwdFile) && File.ReadAllText(cwdFile) == folder, "ConPTY did not use the Unicode folder containing spaces and apostrophes.");
            results.Add("Real ConPTY and PowerShell execute in the saved Unicode project folder");

            var second = (TerminalPaneView)window.AddPane("terminal", wsid, edge: "right")!;
            await Wait(() => second.Terminal.Session?.ProcessId > 0, "Split terminal did not start.");
            Assert(second.Model.DirectoryPath == folder, "Split lost project folder.");
            var firstPid = first.Terminal.Session!.ProcessId; var secondPid = second.Terminal.Session!.ProcessId;
            var layout = JsonSerializer.Serialize(window.Store.Workspace(wsid).Layout);
            window.ToggleFocus(wsid, window.GroupFor(wsid, first.PaneId).Id); await Task.Delay(200); window.RestoreLayout(wsid);
            Assert(first.Terminal.Session.ProcessId == firstPid && second.Terminal.Session.ProcessId == secondPid, "Focus mode restarted a process.");
            Assert(JsonSerializer.Serialize(window.Store.Workspace(wsid).Layout) == layout, "Focus mode changed layout.");
            window.DockPane(wsid, first.PaneId, window.GroupFor(wsid, second.PaneId).Id);
            Assert(first.Terminal.Session.ProcessId == firstPid, "Docking restarted the shell.");
            window.DockPane(wsid, first.PaneId, window.GroupFor(wsid, second.PaneId).Id, "left"); window.SelectPane(wsid, first.PaneId);
            using (var bitmap = new Bitmap(window.ClientSize.Width, window.ClientSize.Height))
            { window.DrawToBitmap(bitmap, new Rectangle(Point.Empty, window.ClientSize)); bitmap.Save(Path.ChangeExtension(outputPath, ".png")); }
            results.Add("Splits, tabs, docking and focus mode preserve shell PIDs and saved layout");

            var interrupted = Path.Combine(AppPaths.Root, "interrupted.txt");
            Send(first, "Start-Sleep -Seconds 60"); await Task.Delay(500);
            var confirmations = 0; window.Confirmation = (_, _) => { confirmations++; return false; };
            window.ClosePane(wsid, first.PaneId); Assert(confirmations == 1 && window.Views.ContainsKey((wsid, first.PaneId)), "Close did not protect a running shell.");
            first.Terminal.Session.Send([3]); Send(first, $"[IO.File]::WriteAllText({Quote(interrupted)}, 'ready')");
            await Wait(() => File.Exists(interrupted), "Ctrl-C did not interrupt the command."); window.Confirmation = (_, _) => true;
            window.ResizeText(1); Assert(new WorkspaceStore(window.Store.FilePath).State.TerminalFontSize == 12, "Font size was not saved."); window.ResizeText(0, true);
            results.Add("Close cancellation protects built-in PowerShell jobs; Ctrl-C and saved font zoom work");

            var browser = (BrowserPaneView)window.AddPane("browser", wsid, value: server.Url)!;
            Assert(await browser.EnsureReady(), "WebView2 failed to initialize.");
            await Wait(() => browser.Web.CoreWebView2.DocumentTitle == "Native Windows test", "Browser did not load local HTTP fixture.");
            Assert(await JavaScript(browser, "document.querySelector('h1').textContent") == "WebView2 works", "Browser content is incorrect.");
            await browser.Web.CoreWebView2.ExecuteScriptAsync("document.cookie='workspace=one;path=/;max-age=86400';localStorage.setItem('workspace','one')");
            var tab = (BrowserPaneView)window.AddPane("browser", wsid, target: window.GroupFor(wsid, browser.PaneId).Id, asTab: true, value: server.Url)!;
            Assert(await tab.EnsureReady(), "Second WebView2 failed.");
            await Wait(() => tab.Web.CoreWebView2.DocumentTitle == "Native Windows test", "Browser tab did not load.");
            Assert(await JavaScript(tab, "localStorage.getItem('workspace')") == "one", "Browser tabs did not share storage.");
            var otherId = window.NewWorkspace("Isolated")!;
            var other = (BrowserPaneView)window.AddPane("browser", otherId, value: server.Url)!;
            Assert(await other.EnsureReady(), "Other workspace browser failed.");
            await Wait(() => other.Web.CoreWebView2.DocumentTitle == "Native Windows test", "Other workspace fixture did not load.");
            Assert(await JavaScript(other, "localStorage.getItem('workspace')") is null, "Browser storage leaked between workspaces.");
            Assert(Alive(firstPid) && Alive(secondPid), "Hidden workspace shell stopped."); window.SwitchWorkspace(wsid);
            var count = window.Views.Count;
            await browser.Web.CoreWebView2.ExecuteScriptAsync("document.querySelector('a').click()");
            await Wait(() => window.Views.Count == count + 1, "Popup did not become a browser tab.");
            results.Add("HTTP browsing, popup tabs, shared browser storage and workspace isolation");

            var markdownFile = Path.Combine(folder, "notes.md"); File.WriteAllText(markdownFile, "# Live preview\n\nVersion one");
            var preview = (PreviewPaneView)window.AddPane("filePreview", wsid, value: markdownFile)!;
            Assert(await preview.EnsureReady(), "Preview WebView2 failed."); await preview.RefreshAsync();
            await WaitAsync(async () => (await preview.Web.CoreWebView2.ExecuteScriptAsync("document.body && document.body.innerText")).Contains("Version one"), "Markdown did not render.");
            File.WriteAllText(markdownFile + ".new", "# Live preview\n\nVersion two"); File.Move(markdownFile + ".new", markdownFile, true);
            await WaitAsync(async () => (await preview.Web.CoreWebView2.ExecuteScriptAsync("document.body && document.body.innerText")).Contains("Version two"), "Atomic saves did not refresh preview.");
            Assert(!preview.Web.CoreWebView2.Settings.IsScriptEnabled, "Preview scripts are enabled.");
            results.Add("Markdown rendering, atomic-save file watching and disabled preview scripts");

            unrelated = Process.Start(new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe"), "/D /c ping -n 60 127.0.0.1 > nul") { UseShellExecute = false, CreateNoWindow = true })!;
            var childFile = Path.Combine(AppPaths.Root, "child.txt");
            Send(first, $"$p = Start-Process $env:ComSpec -ArgumentList '/D /c ping -n 60 127.0.0.1 > nul' -WindowStyle Hidden -PassThru; [IO.File]::WriteAllText({Quote(childFile)}, [string]$p.Id)");
            await Wait(() => File.Exists(childFile) && int.TryParse(File.ReadAllText(childFile), out _), "Child process did not start.");
            var child = int.Parse(File.ReadAllText(childFile)); Assert(first.Terminal.Session.HasChildProcesses(), "PTY job did not account for descendants.");
            window.CloseWorkspace(wsid); await Wait(() => !Alive(firstPid) && !Alive(secondPid) && !Alive(child), "Closing workspace left attached jobs running.");
            Assert(!unrelated.HasExited, "Closing a terminal killed an unrelated process."); Assert(File.Exists(markdownFile), "Project file was removed.");
            window.SwitchWorkspace(wsid);
            var reopened = window.Views.Where(p => p.Key.Workspace == wsid).Select(p => p.Value).OfType<TerminalPaneView>().First();
            await Wait(() => reopened.Terminal.Session?.ProcessId > 0, "Reopened workspace did not start fresh shell."); Assert(reopened.Terminal.Session!.ProcessId != firstPid, "Reopen reused old shell.");
            var reopenedBrowser = window.Views.Where(p => p.Key.Workspace == wsid).Select(p => p.Value).OfType<BrowserPaneView>().First(p => p.Model.Url.Length > 0);
            window.SelectPane(wsid, reopenedBrowser.PaneId); Assert(await reopenedBrowser.EnsureReady(), "Reopened browser failed.");
            await Wait(() => reopenedBrowser.Web.CoreWebView2.DocumentTitle == "Native Windows test", "Reopened browser did not load.");
            Assert(await JavaScript(reopenedBrowser, "localStorage.getItem('workspace')") == "one", "Browser storage did not survive workspace close/reopen.");
            results.Add("Job cleanup is confined to the terminal; project files and browser storage survive reopening");
            Assert(CallbackErrors.IsEmpty, "UI callback errors occurred."); passed = true;
        }
        catch (Exception e) { error = e.ToString(); }
        finally
        {
            if (unrelated is not null) { if (!unrelated.HasExited) unrelated.Kill(true); unrelated.Dispose(); }
            File.WriteAllText(outputPath, JsonSerializer.Serialize(new { passed, checks = results, error, callbackErrors = CallbackErrors.ToArray(), dataDirectory = AppPaths.Root }, new JsonSerializerOptions { WriteIndented = true }));
            Environment.ExitCode = passed ? 0 : 1; window.QuitWithoutPrompt();
        }
    }
    private sealed class FixtureServer : IDisposable
    {
        private readonly TcpListener listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource stop = new();
        public string Url { get; }
        public FixtureServer()
        {
            listener.Start(); Url = $"http://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}/";
            _ = Serve();
        }
        private async Task Serve()
        {
            try
            {
                while (!stop.IsCancellationRequested)
                {
                    var client = await listener.AcceptTcpClientAsync(stop.Token);
                    _ = Task.Run(async () =>
                    {
                        using (client)
                        {
                            var stream = client.GetStream(); var request = new byte[8192]; var length = 0;
                            while (length < request.Length)
                            {
                                var read = await stream.ReadAsync(request.AsMemory(length), stop.Token); if (read == 0) return; length += read;
                                if (Encoding.ASCII.GetString(request, 0, length).Contains("\r\n\r\n")) break;
                            }
                            var body = Encoding.UTF8.GetBytes("<!doctype html><title>Native Windows test</title><h1>WebView2 works</h1><a target='_blank' href='/popup'>New tab</a>");
                            var headers = Encoding.ASCII.GetBytes($"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n");
                            await stream.WriteAsync(headers, stop.Token); await stream.WriteAsync(body, stop.Token);
                        }
                    });
                }
            }
            catch (OperationCanceledException) { }
            catch (ObjectDisposedException) { }
        }
        public void Dispose() { stop.Cancel(); listener.Stop(); stop.Dispose(); }
    }
}
