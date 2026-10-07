using System.Net;
using Markdig;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using MultiTerminal.Core;

namespace MultiTerminal;

internal abstract class PaneView : UserControl
{
    protected readonly MainForm Owner;
    public string WorkspaceId { get; }
    public string PaneId { get; }
    public PaneModel Model => Owner.Store.Pane(WorkspaceId, PaneId);
    protected bool IsOpen => !IsDisposed && !Disposing && Owner.Store.State.OpenWorkspaceIds.Contains(WorkspaceId) && Owner.Store.Workspace(WorkspaceId).Panes.Any(p => p.Id == PaneId);
    protected readonly TableLayoutPanel Body = new() { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, Margin = Padding.Empty };
    protected readonly FlowLayoutPanel Toolbar = new() { Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight, WrapContents = false, Margin = Padding.Empty, BackColor = Ui.Header };
    private readonly TableLayoutPanel status = new() { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, Margin = Padding.Empty, BackColor = Color.FromArgb(50, 43, 30) };
    private readonly Label message = new() { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, AutoEllipsis = true, ForeColor = Color.FromArgb(255, 227, 161), Padding = new Padding(8), Margin = Padding.Empty };
    private readonly Button statusAction;
    private Action? messageAction;

    protected PaneView(MainForm owner, string workspaceId, string paneId)
    {
        Owner = owner; WorkspaceId = workspaceId; PaneId = paneId;
        Dock = DockStyle.Fill; Margin = Padding.Empty; BackColor = Ui.Background;
        Body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Body.RowStyles.Add(new RowStyle(SizeType.Absolute, 0));
        Body.RowStyles.Add(new RowStyle(SizeType.Absolute, 0));
        Body.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        status.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); status.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        statusAction = Ui.Button("Restart", "Apply this action", () => messageAction?.Invoke());
        status.Controls.Add(message, 0, 0); status.Controls.Add(statusAction, 1, 0);
        Body.Controls.Add(Toolbar, 0, 0); Body.Controls.Add(status, 0, 1); Controls.Add(Body);
        Enter += (_, _) => Owner.FocusPane(WorkspaceId, PaneId);
    }
    protected void ShowToolbar(Control toolbar, int height = 38)
    { Body.Controls.Remove(Toolbar); Body.Controls.Add(toolbar, 0, 0); Body.RowStyles[0].Height = height; }
    public void Message(string text, Action? action = null, string actionText = "Restart shell")
    {
        if (IsDisposed) return;
        message.Text = text; Ui.Tips.SetToolTip(message, text); messageAction = action;
        statusAction.Text = actionText; statusAction.Visible = action is not null;
        Body.RowStyles[1].Height = string.IsNullOrEmpty(text) ? 0 : 60;
    }
    public abstract void FocusContent();
}

internal sealed class TerminalPaneView : PaneView
{
    public TerminalSurface Terminal { get; }
    public TerminalPaneView(MainForm owner, string wsid, string paneId) : base(owner, wsid, paneId)
    {
        Terminal = new TerminalSurface(() => Owner.FocusPane(wsid, paneId)) { DirectoryPath = Model.DirectoryPath, Shell = Model.Shell ?? Owner.Store.State.DefaultShell };
        Terminal.StatusChanged += (text, restart) => Message(text, restart ? Restart : null);
        Body.Controls.Add(Terminal, 0, 2); ApplyTheme();
    }
    public void ApplyTheme() => Terminal.Apply(Model.ThemeOverride ?? Owner.Store.State.GlobalTheme, Owner.Store.State.TerminalFontSize);
    public override void FocusContent() => Terminal.Focus();
    public void Restart()
    {
        if (Terminal.IsRunning && !Owner.Confirm("Restart shell?", "The current terminal session and its child processes will stop.")) return;
        Terminal.DirectoryPath = Model.DirectoryPath; Terminal.Shell = Model.Shell ?? Owner.Store.State.DefaultShell; Terminal.Start(); Terminal.Focus();
    }
    public void ChooseDirectory()
    {
        using var picker = new FolderBrowserDialog { Description = "Choose terminal start folder", UseDescriptionForTitle = true, InitialDirectory = Model.DirectoryPath };
        if (picker.ShowDialog(Owner) != DialogResult.OK) return;
        if (Owner.Change(() => Owner.Store.Edit(WorkspaceId, w => w.Panes.Single(p => p.Id == PaneId).DirectoryPath = picker.SelectedPath)))
        { Owner.UpdatePaneTitles(); Message("Start folder saved. Restart the shell to apply it.", Restart, "Restart here"); }
    }
    public void ChangeShell(string? shell)
    {
        if (Owner.Change(() => Owner.Store.Edit(WorkspaceId, w => w.Panes.Single(p => p.Id == PaneId).Shell = shell)))
            Message("Shell profile saved. Restart the shell to apply it.", Restart, "Restart shell");
    }
}

internal abstract class WebPaneView : PaneView
{
    public WebView2 Web { get; } = new() { Dock = DockStyle.Fill, DefaultBackgroundColor = Ui.Background };
    private Task<bool>? initialization;
    protected WebPaneView(MainForm owner, string wsid, string paneId) : base(owner, wsid, paneId)
    {
        Body.Controls.Add(Web, 0, 2);
        Web.Enter += (_, _) => Owner.FocusPane(wsid, paneId);
        Web.HandleCreated += (_, _) => Ui.OnUi(Web, () => _ = EnsureReady());
        Web.KeyDown += (_, e) =>
        {
            if (e.Handled || !Owner.HasShortcut(e.KeyData)) return;
            e.Handled = e.SuppressKeyPress = true;
            // WebView2 blocks its browser process during accelerator callbacks.
            // Run app actions after returning, especially those opening dialogs.
            Ui.Post(Owner, () => Owner.HandleShortcut(e.KeyData));
        };
    }
    protected abstract Task<CoreWebView2Environment> EnvironmentAsync();
    protected abstract Task ConfigureAsync();
    public Task<bool> EnsureReady() => initialization ??= InitializeAsync();
    private async Task<bool> InitializeAsync()
    {
        try
        {
            var environment = await EnvironmentAsync();
            if (IsDisposed) return false;
            await Web.EnsureCoreWebView2Async(environment);
            if (IsDisposed) return false;
            Web.CoreWebView2.Settings.IsWebMessageEnabled = false;
            Web.CoreWebView2.Settings.AreHostObjectsAllowed = false;
            await ConfigureAsync(); Message(""); return true;
        }
        catch (WebView2RuntimeNotFoundException)
        {
            Message("Microsoft Edge WebView2 Runtime is needed for browsers and previews. Terminals remain available.", () => Ui.Open("https://go.microsoft.com/fwlink/p/?LinkId=2124703"), "Install WebView2"); return false;
        }
        catch (Exception e)
        {
            if (!IsDisposed) Message(e.Message, () => { initialization = null; _ = EnsureReady(); }, "Try again");
            return false;
        }
    }
    public override void FocusContent() => Web.Focus();
}

internal sealed class BrowserPaneView : WebPaneView
{
    public TextBox Address { get; } = new() { Dock = DockStyle.Fill, PlaceholderText = "localhost:5173 or https://example.com", Margin = new Padding(3, 6, 3, 3), AccessibleName = "Browser address" };
    private readonly Button back, forward, reload;
    private readonly bool related;
    private bool loading;
    public BrowserPaneView(MainForm owner, string wsid, string paneId, bool related = false) : base(owner, wsid, paneId)
    {
        this.related = related;
        var toolbar = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 5, RowCount = 1, BackColor = Ui.Header, Margin = Padding.Empty };
        for (var i = 0; i < 3; i++) toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 36));
        toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 62));
        back = Ui.Button("‹", "Back", () => { if (Web.CoreWebView2?.CanGoBack == true) Web.GoBack(); });
        forward = Ui.Button("›", "Forward", () => { if (Web.CoreWebView2?.CanGoForward == true) Web.GoForward(); });
        reload = Ui.Button("↻", "Reload or stop", () => { if (loading) Web.CoreWebView2?.Stop(); else Web.CoreWebView2?.Reload(); });
        toolbar.Controls.Add(back, 0, 0); toolbar.Controls.Add(forward, 1, 0); toolbar.Controls.Add(reload, 2, 0); toolbar.Controls.Add(Address, 3, 0);
        toolbar.Controls.Add(Ui.Button("Open", "Open in your default browser", () => { if (Web.Source?.Scheme is "http" or "https") Ui.Open(Web.Source.AbsoluteUri); }), 4, 0);
        Address.Text = Model.Url;
        Address.KeyDown += async (_, e) => { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; await Navigate(Address.Text); } };
        back.Enabled = forward.Enabled = false; ShowToolbar(toolbar);
    }
    protected override Task<CoreWebView2Environment> EnvironmentAsync() => Owner.Environments.Get(WorkspaceId);
    protected override Task ConfigureAsync()
    {
        var core = Web.CoreWebView2;
        core.HistoryChanged += (_, _) => { back.Enabled = core.CanGoBack; forward.Enabled = core.CanGoForward; };
        core.SourceChanged += (_, _) =>
        {
            if (!IsOpen) return;
            if (!Uri.TryCreate(core.Source, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https")) return;
            Address.Text = uri.AbsoluteUri;
            if (Model.Url != uri.AbsoluteUri && Owner.Change(() => Owner.Store.Edit(WorkspaceId, w => w.Panes.Single(p => p.Id == PaneId).Url = uri.AbsoluteUri))) Owner.UpdatePaneTitles();
        };
        core.NavigationStarting += (_, e) =>
        {
            loading = true; reload.Text = "×";
            if (!Uri.TryCreate(e.Uri, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https" or "about")) { e.Cancel = true; Message("Only HTTP and HTTPS navigation is supported."); }
        };
        core.NavigationCompleted += (_, e) => { loading = false; reload.Text = "↻"; if (!e.IsSuccess) Message($"Could not load this page: {e.WebErrorStatus}", () => core.Reload(), "Reload"); else Message(""); };
        core.ProcessFailed += (_, e) => Message($"Browser process stopped: {e.ProcessFailedKind}", () => core.Reload(), "Reload");
        core.NewWindowRequested += async (_, e) =>
        {
            using var deferral = e.GetDeferral(); e.Handled = true;
            if (!IsOpen) return;
            try
            {
                WorkspaceStore.NormalizeUrl(e.Uri);
                var pane = Owner.AddPane("browser", WorkspaceId, target: Owner.GroupFor(WorkspaceId, PaneId).Id, asTab: true, related: true) as BrowserPaneView;
                if (pane is not null && await pane.EnsureReady()) e.NewWindow = pane.Web.CoreWebView2;
                else Message("Could not open a browser tab.");
            }
            catch (Exception error) { Ui.Post(Owner, () => Owner.Error(error.Message)); }
        };
        core.DownloadStarting += (_, e) =>
        {
            e.Cancel = true; e.Handled = true;
            var uri = e.DownloadOperation.Uri;
            // Return from the WebView2 callback before opening a modal dialog.
            Ui.Post(Owner, () =>
            {
                if (IsOpen && Owner.Confirm("Open download in your browser?", "Downloads are handled by your default browser."))
                { try { Ui.Open(WorkspaceStore.NormalizeUrl(uri)); } catch (Exception error) { Owner.Error(error.Message); } }
            });
        };
        if (!related)
        {
            if (Model.Url.Length > 0) core.Navigate(Model.Url);
            else core.NavigateToString("<html><body style='background:#101522;color:#dce5f5;font:18px Segoe UI;padding:40px'><h2>Your app, beside your tools.</h2><p>Enter a website or localhost address above.</p></body></html>");
        }
        return Task.CompletedTask;
    }
    public async Task Navigate(string address)
    {
        try
        {
            var uri = WorkspaceStore.NormalizeUrl(address);
            if (uri.Length > 0 && await EnsureReady()) { Message(""); Web.CoreWebView2.Navigate(uri); Web.Focus(); }
        }
        catch (Exception e) { Message(e.Message); }
    }
    public override void FocusContent() { if (Model.Url.Length == 0) Address.Focus(); else Web.Focus(); }
}

internal sealed class PreviewPaneView : WebPaneView
{
    private readonly Label pathLabel = new() { AutoSize = false, Width = 220, Height = 32, ForeColor = Ui.Foreground, TextAlign = ContentAlignment.MiddleLeft, AutoEllipsis = true };
    private readonly System.Windows.Forms.Timer debounce = new() { Interval = 250 };
    private FileSystemWatcher? watcher;
    private int generation;
    private readonly string previewProfile = Path.Combine(AppPaths.Root, "Previews", Guid.NewGuid().ToString());
    public PreviewPaneView(MainForm owner, string wsid, string paneId) : base(owner, wsid, paneId)
    {
        Toolbar.Controls.Add(pathLabel);
        Toolbar.Controls.Add(Ui.Button("Choose", "Choose a file to preview", Choose));
        Toolbar.Controls.Add(Ui.Button("Refresh", "Refresh file preview", () => _ = RefreshAsync()));
        Toolbar.Controls.Add(Ui.Button("Open", "Open file in its default application", () => { if (File.Exists(Model.Path)) Ui.Open(Model.Path); }));
        Body.RowStyles[0].Height = 38;
        debounce.Tick += (_, _) => { debounce.Stop(); _ = RefreshAsync(); };
        Watch();
    }
    protected override Task<CoreWebView2Environment> EnvironmentAsync() => CoreWebView2Environment.CreateAsync(userDataFolder: previewProfile);
    protected override Task ConfigureAsync()
    {
        Web.CoreWebView2.Settings.IsScriptEnabled = false;
        Web.CoreWebView2.Settings.AreDevToolsEnabled = false;
        Web.CoreWebView2.Settings.AreDefaultScriptDialogsEnabled = false;
        Web.CoreWebView2.NewWindowRequested += (_, e) => e.Handled = true;
        return Task.CompletedTask;
    }
    public void Choose()
    {
        using var picker = new OpenFileDialog { Title = "Choose a file to preview", CheckFileExists = true };
        if (picker.ShowDialog(Owner) != DialogResult.OK) return;
        if (Owner.Change(() => Owner.Store.Edit(WorkspaceId, w => w.Panes.Single(p => p.Id == PaneId).Path = picker.FileName)))
        { Watch(); Owner.UpdatePaneTitles(); _ = RefreshAsync(); }
    }
    protected override void OnVisibleChanged(EventArgs e)
    { base.OnVisibleChanged(e); if (Visible && IsHandleCreated) _ = RefreshAsync(); }
    private void Watch()
    {
        watcher?.Dispose(); watcher = null; pathLabel.Text = Path.GetFileName(Model.Path); Ui.Tips.SetToolTip(pathLabel, Model.Path);
        if (Model.Path.Length == 0) return;
        var directory = Path.GetDirectoryName(Model.Path);
        if (!Directory.Exists(directory)) return;
        try
        {
            watcher = new FileSystemWatcher(directory!, Path.GetFileName(Model.Path)) { NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size };
            FileSystemEventHandler changed = (_, _) => Schedule(); RenamedEventHandler renamed = (_, _) => Schedule();
            watcher.Changed += changed; watcher.Created += changed; watcher.Deleted += changed; watcher.Renamed += renamed;
            watcher.EnableRaisingEvents = true;
        }
        catch (Exception e) { Message(e.Message); }
    }
    private void Schedule() => Ui.OnUi(this, () => { debounce.Stop(); debounce.Start(); });
    public async Task RefreshAsync()
    {
        var current = ++generation;
        try
        {
            if (!await EnsureReady() || !IsOpen || current != generation) return;
            var path = Model.Path;
            if (path.Length == 0) { Web.NavigateToString(Wrap("<h2>Live file preview</h2><p>Choose a Markdown, HTML, text or image file.</p>", "")); return; }
            if (!File.Exists(path)) { Message("The file is unavailable. The preview will refresh when it returns."); return; }
            var extension = Path.GetExtension(path).ToLowerInvariant();
            var image = new[] { ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg" }.Contains(extension);
            var limit = image ? 20 * 1024 * 1024 : 10 * 1024 * 1024;
            if (new FileInfo(path).Length > limit) throw new InvalidDataException($"Preview size limit is {limit / 1024 / 1024} MB. Open the file in its default application.");
            Web.CoreWebView2.SetVirtualHostNameToFolderMapping("preview.multiterminal.invalid", Path.GetDirectoryName(path)!, CoreWebView2HostResourceAccessKind.DenyCors);
            if (image || extension is ".html" or ".htm") Web.CoreWebView2.Navigate("https://preview.multiterminal.invalid/" + Uri.EscapeDataString(Path.GetFileName(path)));
            else if (extension is ".pdf" or ".zip" or ".exe" or ".dll" or ".docx" or ".xlsx")
            { Web.NavigateToString(Wrap("<h2>Open this file in its default application</h2><p>Use Open above. Previews do not edit project files.</p>", "")); }
            else
            {
                using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536, FileOptions.Asynchronous);
                var bytes = new byte[limit + 1]; var count = 0;
                while (count < bytes.Length)
                { var read = await stream.ReadAsync(bytes.AsMemory(count)); if (read == 0) break; count += read; }
                if (count > limit) throw new InvalidDataException("The file grew beyond the preview size limit.");
                using var reader = new StreamReader(new MemoryStream(bytes, 0, count), detectEncodingFromByteOrderMarks: true);
                var text = await reader.ReadToEndAsync();
                if (IsDisposed || current != generation) return;
                if (text.Contains('\0')) throw new InvalidDataException("Binary files should be opened in their default application.");
                var html = extension is ".md" or ".markdown" ? Markdown.ToHtml(text, new MarkdownPipelineBuilder().UseAdvancedExtensions().Build()) : "<pre>" + WebUtility.HtmlEncode(text) + "</pre>";
                Web.NavigateToString(Wrap(html, path));
            }
            Message("");
        }
        catch (Exception e) { if (!IsDisposed && current == generation) Message(e.Message); }
    }
    private static string Wrap(string body, string path)
    {
        var baseTag = path.Length > 0 ? "<base href='https://preview.multiterminal.invalid/'>" : "";
        return $"<!doctype html><html><head><meta charset='utf-8'><meta http-equiv='Content-Security-Policy' content=\"script-src 'none'; object-src 'none'; frame-src 'none'\">{baseTag}<style>body{{background:#101522;color:#dce5f5;font:15px/1.6 Segoe UI;padding:24px}}a{{color:#82aaff}}pre,code{{font-family:Consolas;white-space:pre-wrap}}pre{{padding:16px;background:#182231}}table{{border-collapse:collapse}}td,th{{border:1px solid #34435d;padding:6px}}img{{max-width:100%}}</style></head><body>{body}</body></html>";
    }
    protected override void Dispose(bool disposing)
    { if (disposing) { generation++; watcher?.Dispose(); debounce.Dispose(); } base.Dispose(disposing); }
    public override void FocusContent() { _ = RefreshAsync(); base.FocusContent(); }
}
