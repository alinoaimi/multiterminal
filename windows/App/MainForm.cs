using System.ComponentModel;
using System.Runtime.InteropServices;
using MultiTerminal.Core;
using WorkspaceLayout = MultiTerminal.Core.Layout;

namespace MultiTerminal;

internal sealed class MainForm : Form
{
    public WorkspaceStore Store { get; }
    public BrowserEnvironments Environments { get; } = new();
    public Dictionary<(string Workspace, string Pane), PaneView> Views { get; } = [];
    private readonly Dictionary<string, Panel> pages = [];
    private readonly Dictionary<(string Workspace, string Group), PaneGroup> groups = [];
    private readonly Dictionary<string, Button> workspaceButtons = [];
    private readonly Dictionary<string, string> focusedGroups = [];
    private readonly Dictionary<(string Workspace, string Node), (System.Windows.Forms.Timer Timer, double Percent)> splitSaves = [];
    private readonly FlowLayoutPanel workspaceTabs = new() { Dock = DockStyle.Fill, WrapContents = false, AutoScroll = true, Margin = Padding.Empty, BackColor = Ui.Header };
    private readonly Panel body = new() { Dock = DockStyle.Fill, BackColor = Ui.Background, Padding = new Padding(6), Margin = Padding.Empty };
    private readonly Label status = new() { Dock = DockStyle.Fill, ForeColor = Color.FromArgb(147, 168, 198), TextAlign = ContentAlignment.MiddleLeft, AutoEllipsis = true, Padding = new Padding(10, 0, 10, 0) };
    private readonly Label hint = new() { AutoSize = true, ForeColor = Color.FromArgb(147, 168, 198), Text = "Ctrl+Shift+Enter  Focus pane", Anchor = AnchorStyles.Right, Padding = new Padding(10, 0, 10, 0) };
    private readonly Button restore, open;
    private readonly Panel empty = new() { Dock = DockStyle.Fill };
    private bool rebuilding, quitting;
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public Func<string, string, bool>? Confirmation { get; set; }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public Action<string>? ErrorHandler { get; set; }
    public string? Active => Store.State.ActiveWorkspaceId;

    public MainForm(WorkspaceStore store)
    {
        Store = store;
        Text = "MultiTerminal"; BackColor = Ui.Background; ForeColor = Ui.Foreground; Font = new Font("Segoe UI", 10);
        AutoScaleMode = AutoScaleMode.Dpi; AutoScaleDimensions = new SizeF(96, 96);
        Size = new Size(1280, 850); MinimumSize = new Size(720, 480); StartPosition = FormStartPosition.CenterScreen;
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        var root = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 4, Margin = Padding.Empty };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 42)); root.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); root.RowStyles.Add(new RowStyle(SizeType.Absolute, 26));
        var toolbar = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, BackColor = Ui.Header, Margin = Padding.Empty };
        toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var actions = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, Padding = new Padding(4), Margin = Padding.Empty };
        actions.Controls.Add(Ui.Button("New Terminal", "New terminal · Ctrl+Shift+T", () => AddPane("terminal"), true));
        Button add = null!; add = Ui.Button("Add Pane ▾", "Add a terminal, browser or live preview", () => ShowAdd(add, Active, null)); actions.Controls.Add(add);
        restore = Ui.Button("Restore Layout", "Leave pane focus mode · Escape", () => RestoreLayout()); restore.Visible = false; actions.Controls.Add(restore);
        Button options = null!; options = Ui.Button("☰", "Workspace, shell, appearance and help options", () => ShowOptions(options));
        toolbar.Controls.Add(actions, 0, 0); toolbar.Controls.Add(options, 1, 0); root.Controls.Add(toolbar, 0, 0);
        var strip = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, BackColor = Ui.Header, Margin = Padding.Empty };
        strip.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); strip.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var workspaceActions = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = Padding.Empty };
        workspaceActions.Controls.Add(Ui.Button("+ Workspace", "Name a workspace and choose a start folder · Ctrl+Shift+N", () => WorkspaceDialog()));
        open = Ui.Button("Open ▾", "Reopen a saved workspace", ShowOpen); workspaceActions.Controls.Add(open);
        strip.Controls.Add(workspaceTabs, 0, 0); strip.Controls.Add(workspaceActions, 1, 0); root.Controls.Add(strip, 0, 1);
        var emptyFlow = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, Padding = new Padding(40), BackColor = Ui.Background };
        emptyFlow.Controls.Add(new Label { Text = "Make room for your whole workflow.", AutoSize = true, Font = new Font("Segoe UI", 18), ForeColor = Ui.Foreground });
        emptyFlow.Controls.Add(Ui.Button("New Workspace", "Create a workspace", () => WorkspaceDialog(), true));
        empty.Controls.Add(emptyFlow); body.Controls.Add(empty); root.Controls.Add(body, 0, 2);
        var footer = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, BackColor = Ui.Header, Margin = Padding.Empty };
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        footer.Controls.Add(status, 0, 0); footer.Controls.Add(hint, 1, 0); root.Controls.Add(footer, 0, 3); Controls.Add(root);
        foreach (var wsid in Store.State.OpenWorkspaceIds) Render(wsid);
        SyncTabs(); Shown += (_, _) => FocusSelected();
    }
    protected override void OnHandleCreated(EventArgs e)
    { base.OnHandleCreated(e); var enabled = 1; DwmSetWindowAttribute(Handle, 20, ref enabled, sizeof(int)); }
    public bool Change(Action action)
    {
        try { action(); return true; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException or ArgumentException or InvalidOperationException or Win32Exception)
        { Error(e.Message); return false; }
    }
    public void Error(string text)
    { if (ErrorHandler is not null) ErrorHandler(text); else MessageBox.Show(this, text, "MultiTerminal", MessageBoxButtons.OK, MessageBoxIcon.Information); }
    public bool Confirm(string title, string text) => Confirmation?.Invoke(title, text) ?? MessageBox.Show(this, text, title, MessageBoxButtons.OKCancel, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) == DialogResult.OK;
    public LayoutNode GroupFor(string wsid, string paneId) => WorkspaceLayout.Groups(Store.Workspace(wsid).Layout).Single(g => g.PaneIds.Contains(paneId));
    public PaneView? SelectedView()
    {
        if (Active is not { } wsid) return null;
        var ws = Store.Workspace(wsid); var group = WorkspaceLayout.Groups(ws.Layout).FirstOrDefault(g => g.Id == ws.FocusedGroupId);
        return group is not null && Views.TryGetValue((wsid, group.SelectedPaneId!), out var pane) ? pane : null;
    }
    private void WorkspaceDialog(string? wsid = null)
    {
        using var dialog = new WorkspaceNameDialog(wsid is null ? $"Workspace {Store.State.Workspaces.Count + 1}" : Store.Workspace(wsid).Name, wsid is null);
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        if (wsid is null) NewWorkspace(dialog.WorkspaceName, dialog.Folder);
        else if (Change(() => Store.Edit(wsid, w => w.Name = dialog.WorkspaceName))) { SyncTabs(); FocusSelected(); }
    }
    public string? NewWorkspace(string? name = null, string? directory = null)
    {
        string? id = null;
        if (Change(() => id = Store.Create(name, directory))) { Render(id!); SyncTabs(); FocusSelected(); }
        return id;
    }
    public void SwitchWorkspace(string id)
    {
        if (id == Active) return;
        if (!Change(() => Store.Open(id))) return;
        if (!pages.ContainsKey(id)) Render(id);
        foreach (var (wsid, page) in pages) page.Visible = wsid == id;
        foreach (var (wsid, button) in workspaceButtons) button.BackColor = wsid == id ? Ui.Accent : Ui.Header;
        if (!workspaceButtons.ContainsKey(id)) SyncTabs();
        UpdateStatus(); FocusSelected();
    }
    private void SyncTabs()
    {
        foreach (Control c in workspaceTabs.Controls.Cast<Control>().ToArray()) c.Dispose(); workspaceButtons.Clear();
        foreach (var wsid in Store.State.OpenWorkspaceIds)
        {
            var ws = Store.Workspace(wsid);
            var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(2), BackColor = wsid == Active ? Ui.Accent : Ui.Header };
            var name = new WorkspaceTabButton { Text = ws.Name, Width = Math.Clamp(ws.Name.Length * 8 + 24, 100, 190), Height = 30, FlatStyle = FlatStyle.Flat, BackColor = row.BackColor, ForeColor = Ui.Foreground, AutoEllipsis = true, AccessibleName = "Workspace " + ws.Name, Margin = Padding.Empty };
            name.FlatAppearance.BorderSize = 0; Ui.Tips.SetToolTip(name, ws.Name + " · Double-click to rename · F2");
            name.Click += (_, _) => SwitchWorkspace(wsid); name.DoubleClick += (_, _) => WorkspaceDialog(wsid);
            row.Controls.Add(name); row.Controls.Add(Ui.Button("×", "Close workspace; keep its saved layout", () => CloseWorkspace(wsid)));
            workspaceButtons[wsid] = name; workspaceTabs.Controls.Add(row);
        }
        open.Enabled = Store.State.Workspaces.Any(w => !Store.State.OpenWorkspaceIds.Contains(w.Id));
        foreach (var (id, page) in pages) page.Visible = id == Active;
        empty.Visible = Active is null; if (Active is null) empty.BringToFront(); UpdateStatus();
    }
    private void ShowOpen()
    {
        var menu = Ui.Menu();
        foreach (var ws in Store.State.Workspaces.Where(w => !Store.State.OpenWorkspaceIds.Contains(w.Id))) Ui.Item(menu, ws.Name, () => SwitchWorkspace(ws.Id));
        menu.Closed += (_, _) => menu.Dispose(); menu.Show(open, new Point(0, open.Height));
    }
    public PaneView? AddPane(string kind, string? wsid = null, string? target = null, string? edge = null, bool asTab = false, string value = "", bool related = false)
    {
        if (kind == "filePreview" && value.Length == 0)
        {
            using var picker = new OpenFileDialog { Title = "Choose a file to preview", CheckFileExists = true };
            if (picker.ShowDialog(this) != DialogResult.OK) return null; value = picker.FileName;
        }
        wsid ??= Active ?? NewWorkspace(); if (wsid is null) return null;
        var ws = Store.Workspace(wsid);
        if (edge is null)
        {
            groups.TryGetValue((wsid, target ?? ws.FocusedGroupId ?? ""), out var region);
            edge = region is not null && region.Height > region.Width ? "bottom" : "right";
        }
        var pane = new PaneModel { Kind = kind };
        if (kind == "terminal")
        {
            var selected = WorkspaceLayout.Groups(ws.Layout).FirstOrDefault(g => g.Id == (target ?? ws.FocusedGroupId));
            var source = ws.Panes.FirstOrDefault(p => p.Id == selected?.SelectedPaneId && p.Kind == "terminal") ?? ws.Panes.FirstOrDefault(p => p.Kind == "terminal");
            pane.DirectoryPath = value.Length > 0 ? value : source?.DirectoryPath ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        }
        else if (kind == "browser") { try { pane.Url = WorkspaceStore.NormalizeUrl(value); } catch (Exception e) { Error(e.Message); return null; } }
        else pane.Path = Path.GetFullPath(value);
        if (!Change(() => Store.Add(wsid, pane, target, edge, asTab))) return null;
        if (related) Views[(wsid, pane.Id)] = new BrowserPaneView(this, wsid, pane.Id, true);
        if (!asTab) focusedGroups.Remove(wsid);
        Render(wsid); SyncTabs(); var view = Views[(wsid, pane.Id)]; view.FocusContent(); return view;
    }
    public void ShowAdd(Control anchor, string? wsid, string? target)
    {
        var menu = Ui.Menu();
        foreach (var (label, placement) in new[] { ("New tab", "tab"), ("Split right", "right"), ("Split below", "bottom") })
        {
            var submenu = new ToolStripMenuItem(label) { ForeColor = Ui.Foreground, BackColor = Ui.Header };
            foreach (var (typeName, kind) in new[] { ("Terminal", "terminal"), ("Browser", "browser"), ("File preview…", "filePreview") })
                Ui.Item(submenu.DropDown, typeName, () => AddPane(kind, wsid, target, placement == "tab" ? "right" : placement, placement == "tab"));
            menu.Items.Add(submenu);
        }
        menu.Closed += (_, _) => menu.Dispose(); menu.Show(anchor, new Point(0, anchor.Height));
    }
    public void ShowSplit(Control anchor, string wsid, string gid)
    {
        var menu = Ui.Menu(); Ui.Item(menu, "Split right", () => AddPane("terminal", wsid, gid, "right")); Ui.Item(menu, "Split below", () => AddPane("terminal", wsid, gid, "bottom"));
        menu.Closed += (_, _) => menu.Dispose(); menu.Show(anchor, new Point(0, anchor.Height));
    }
    private void ShowOptions(Control anchor)
    {
        var menu = Ui.Menu();
        if (Active is { } wsid)
        {
            Ui.Item(menu, "Rename workspace…\tF2", () => WorkspaceDialog(wsid)); Ui.Item(menu, "Close workspace", () => CloseWorkspace(wsid));
            Ui.Item(menu, "Delete workspace…", () => CloseWorkspace(wsid, true)); menu.Items.Add(new ToolStripSeparator());
        }
        foreach (var (label, theme) in new[] { ("Midnight", "midnight"), ("High Contrast", "highContrast"), ("Amber", "amber") })
            Ui.Item(menu, label + " theme", () => { if (Change(() => Store.Commit(s => s.GlobalTheme = theme))) ApplyAppearance(); }, Store.State.GlobalTheme == theme);
        var shells = new ToolStripMenuItem("Default shell") { ForeColor = Ui.Foreground, BackColor = Ui.Header };
        foreach (var shell in WorkspaceStore.Shells) Ui.Item(shells.DropDown, ShellName(shell), () => Change(() => Store.Commit(s => s.DefaultShell = shell)), Store.State.DefaultShell == shell);
        menu.Items.Add(shells); menu.Items.Add(new ToolStripSeparator());
        Ui.Item(menu, "Larger terminal text\tCtrl++", () => ResizeText(1)); Ui.Item(menu, "Smaller terminal text\tCtrl+−", () => ResizeText(-1)); Ui.Item(menu, "Reset terminal text\tCtrl+0", () => ResizeText(0, true));
        menu.Items.Add(new ToolStripSeparator()); Ui.Item(menu, "Help and keyboard shortcuts", Help);
        Ui.Item(menu, "About MultiTerminal", () => Error("MultiTerminal 0.1.0-windows.1\nNative Windows Forms, ConPTY, VtNetCore and Edge WebView2.\n© 2026 Ali Alnoaimi\nAGPL-3.0-only. See LICENSE.txt beside the application."));
        Ui.Item(menu, "Quit", Close); menu.Closed += (_, _) => menu.Dispose(); menu.Show(anchor, new Point(0, anchor.Height));
    }
    public static string ShellName(string shell) => shell switch { "powershell" => "Windows PowerShell", "pwsh" => "PowerShell 7 (install separately)", "cmd" => "Command Prompt", "wsl" => "WSL (install separately)", _ => shell };
    public void ShowPaneMenu(Control anchor, string wsid, string gid)
    {
        var group = WorkspaceLayout.Groups(Store.Workspace(wsid).Layout).Single(g => g.Id == gid);
        var pid = group.SelectedPaneId!; var menu = Ui.Menu();
        if (Views[(wsid, pid)] is TerminalPaneView terminal)
        {
            Ui.Item(menu, "Copy\tCtrl+Shift+C", terminal.Terminal.Copy); Ui.Item(menu, "Paste\tCtrl+Shift+V", terminal.Terminal.Paste);
            Ui.Item(menu, "Change start folder…", terminal.ChooseDirectory); Ui.Item(menu, "Restart shell", terminal.Restart);
            Ui.Item(menu, "Open start folder", () => Change(() => Ui.Open(Store.Pane(wsid, pid).DirectoryPath)));
            var profiles = new ToolStripMenuItem("Shell profile") { BackColor = Ui.Header, ForeColor = Ui.Foreground };
            Ui.Item(profiles.DropDown, "Follow default shell", () => terminal.ChangeShell(null), terminal.Model.Shell is null);
            foreach (var shell in WorkspaceStore.Shells) Ui.Item(profiles.DropDown, ShellName(shell), () => terminal.ChangeShell(shell), terminal.Model.Shell == shell);
            menu.Items.Add(profiles);
            var themes = new ToolStripMenuItem("Terminal theme") { BackColor = Ui.Header, ForeColor = Ui.Foreground };
            foreach (var theme in new string?[] { null, "midnight", "highContrast", "amber" })
                Ui.Item(themes.DropDown, theme ?? "Follow workspace theme", () => { if (Change(() => Store.Edit(wsid, w => w.Panes.Single(p => p.Id == pid).ThemeOverride = theme))) terminal.ApplyTheme(); }, terminal.Model.ThemeOverride == theme);
            menu.Items.Add(themes); menu.Items.Add(new ToolStripSeparator());
        }
        foreach (var dest in WorkspaceLayout.Groups(Store.Workspace(wsid).Layout))
        {
            var move = new ToolStripMenuItem("Move to " + PaneTitle(Store.Pane(wsid, dest.SelectedPaneId!))) { BackColor = Ui.Header, ForeColor = Ui.Foreground };
            if (dest.Id != gid) Ui.Item(move.DropDown, "As a tab", () => DockPane(wsid, pid, dest.Id));
            if (dest.Id != gid || group.PaneIds.Count > 1)
                foreach (var edge in new[] { "left", "right", "top", "bottom" }) Ui.Item(move.DropDown, "Split " + edge, () => DockPane(wsid, pid, dest.Id, edge));
            if (move.DropDownItems.Count > 0) menu.Items.Add(move); else move.Dispose();
        }
        menu.Items.Add(new ToolStripSeparator()); Ui.Item(menu, "Close pane", () => ClosePane(wsid, pid));
        menu.Closed += (_, _) => menu.Dispose(); menu.Show(anchor, new Point(0, anchor.Height));
    }
    public void ClosePane(string wsid, string pid)
    {
        if (Views[(wsid, pid)] is TerminalPaneView terminal && terminal.Terminal.IsRunning && !Confirm("Close terminal?", "Its shell and child processes will stop.")) return;
        if (!Change(() => Store.Remove(wsid, pid))) return;
        var view = Views[(wsid, pid)]; Views.Remove((wsid, pid)); view.Parent?.Controls.Remove(view); view.Dispose(); Render(wsid); FocusSelected();
    }
    public async void CloseWorkspace(string wsid, bool delete = false)
    {
        var running = Views.Where(p => p.Key.Workspace == wsid).Select(p => p.Value).OfType<TerminalPaneView>().Any(p => p.Terminal.IsRunning);
        if ((delete || running) && !Confirm(delete ? "Delete workspace?" : "Close workspace?", delete ? "Its sessions will stop and its settings and browser profile will be removed. Project files are kept." : "Its terminal sessions and child processes will stop. The workspace remains saved.")) return;
        if (delete)
        {
            var browser = Views.Where(p => p.Key.Workspace == wsid).Select(p => p.Value).OfType<BrowserPaneView>().FirstOrDefault(p => p.Web.CoreWebView2 is not null);
            if (browser is not null) { try { await browser.Web.CoreWebView2.Profile.ClearBrowsingDataAsync(); } catch (Exception e) { Error(e.Message); return; } }
        }
        if (!Change(() => Store.Close(wsid, delete))) return;
        FlushSplits(wsid, false);
        foreach (var key in Views.Keys.Where(k => k.Workspace == wsid).ToArray()) { Views[key].Dispose(); Views.Remove(key); }
        foreach (var key in groups.Keys.Where(k => k.Workspace == wsid).ToArray()) groups.Remove(key);
        if (pages.Remove(wsid, out var page)) { body.Controls.Remove(page); page.Dispose(); }
        focusedGroups.Remove(wsid); Environments.Forget(wsid); SyncTabs(); FocusSelected();
        if (delete)
        {
            var folder = AppPaths.Browser(wsid);
            _ = Task.Run(async () =>
            {
                for (var attempt = 0; attempt < 20; attempt++)
                { try { if (Directory.Exists(folder)) Directory.Delete(folder, true); return; } catch (IOException) { await Task.Delay(250); } catch (UnauthorizedAccessException) { break; } }
                Ui.OnUi(this, () => Error("The workspace was deleted, but its browser profile is still locked. Close MultiTerminal before removing " + folder));
            });
        }
    }
    public void SelectPane(string wsid, string pid)
    { if (Change(() => Store.Select(wsid, pid))) { RefreshGroups(wsid); UpdateStatus(); Views[(wsid, pid)].FocusContent(); } }
    public void FocusPane(string wsid, string pid)
    {
        if (rebuilding || quitting || !Views.ContainsKey((wsid, pid))) return;
        var group = GroupFor(wsid, pid);
        if (Store.Workspace(wsid).FocusedGroupId != group.Id && Change(() => Store.Select(wsid, pid))) { RefreshGroups(wsid); UpdateStatus(); }
    }
    public void FocusSelected() => SelectedView()?.FocusContent();
    public void ToggleFocus(string? wsid = null, string? gid = null)
    {
        wsid ??= Active; if (wsid is null) return;
        gid ??= Store.Workspace(wsid).FocusedGroupId; if (gid is null) return;
        if (focusedGroups.GetValueOrDefault(wsid) == gid) { RestoreLayout(wsid); return; }
        if (WorkspaceLayout.Groups(Store.Workspace(wsid).Layout).Count() < 2) return;
        var group = WorkspaceLayout.Groups(Store.Workspace(wsid).Layout).Single(g => g.Id == gid);
        if (!Change(() => Store.Select(wsid, group.SelectedPaneId!))) return;
        focusedGroups[wsid] = gid; Render(wsid); FocusSelected();
    }
    public void RestoreLayout(string? wsid = null)
    { wsid ??= Active; if (wsid is not null && focusedGroups.Remove(wsid)) { Render(wsid); FocusSelected(); } }
    public bool DockPane(string wsid, string pid, string target, string? edge = null, string? before = null)
    { if (!Change(() => Store.Dock(wsid, pid, target, edge, before))) return false; focusedGroups.Remove(wsid); Render(wsid); FocusSelected(); return true; }
    public void ResizeText(int delta, bool reset = false)
    { if (Change(() => Store.Commit(s => s.TerminalFontSize = reset ? 11 : Math.Clamp(s.TerminalFontSize + delta, 8, 24)))) ApplyAppearance(); }
    private void ApplyAppearance() { foreach (var pane in Views.Values.OfType<TerminalPaneView>()) pane.ApplyTheme(); }
    public void UpdatePaneTitles() { foreach (var group in groups.Values) group.UpdateTitles(); UpdateStatus(); }
    private void RefreshGroups(string wsid) { foreach (var pair in groups.Where(p => p.Key.Workspace == wsid)) pair.Value.UpdateSelection(); }
    public static string PaneTitle(PaneModel model) => model.Kind switch
    {
        "terminal" => Path.GetFileName(model.DirectoryPath.TrimEnd(Path.DirectorySeparatorChar)) is { Length: > 0 } name ? name : "Terminal",
        "browser" => Uri.TryCreate(model.Url, UriKind.Absolute, out var uri) ? uri.Host : "Browser",
        _ => Path.GetFileName(model.Path) is { Length: > 0 } name ? name : "File preview"
    };
    private void UpdateStatus()
    {
        var pane = SelectedView(); restore.Visible = Active is not null && focusedGroups.ContainsKey(Active);
        hint.Text = restore.Visible ? "Escape  Restore layout" : "Ctrl+Shift+Enter  Focus pane";
        Text = Active is { } wsid ? Store.Workspace(wsid).Name + " · MultiTerminal" : "MultiTerminal";
        status.Text = pane is null ? "Create a workspace or add a pane to get started." : pane.Model.Kind switch { "terminal" => "Terminal · Start folder: " + pane.Model.DirectoryPath, "browser" => "Browser · " + pane.Model.Url, _ => "Live preview · " + pane.Model.Path };
        Ui.Tips.SetToolTip(status, status.Text);
    }
    private void Render(string wsid)
    {
        rebuilding = true;
        try
        {
            FlushSplits(wsid, true);
            foreach (var pair in Views.Where(p => p.Key.Workspace == wsid)) pair.Value.Parent?.Controls.Remove(pair.Value);
            if (!pages.TryGetValue(wsid, out var page)) { page = new Panel { Dock = DockStyle.Fill, Visible = wsid == Active }; pages[wsid] = page; body.Controls.Add(page); }
            foreach (Control c in page.Controls.Cast<Control>().ToArray()) c.Dispose();
            foreach (var key in groups.Keys.Where(k => k.Workspace == wsid).ToArray()) groups.Remove(key);
            var layout = Store.Workspace(wsid).Layout;
            var zoomed = WorkspaceLayout.Groups(layout).FirstOrDefault(g => g.Id == focusedGroups.GetValueOrDefault(wsid));
            if (zoomed is null) focusedGroups.Remove(wsid);
            if (layout is not null) page.Controls.Add(BuildNode(wsid, zoomed ?? layout));
            else page.Controls.Add(new Label { Dock = DockStyle.Fill, Text = "Use New Terminal or Add Pane to get started.", TextAlign = ContentAlignment.MiddleCenter, ForeColor = Ui.Foreground });
        }
        finally { rebuilding = false; }
        UpdateStatus();
    }
    private Control BuildNode(string wsid, LayoutNode node)
    {
        if (node.Type == "group")
        {
            foreach (var pid in node.PaneIds)
                if (!Views.ContainsKey((wsid, pid))) Views[(wsid, pid)] = Store.Pane(wsid, pid).Kind switch { "terminal" => new TerminalPaneView(this, wsid, pid), "browser" => new BrowserPaneView(this, wsid, pid), _ => new PreviewPaneView(this, wsid, pid) };
            var group = new PaneGroup(this, wsid, node.Id); groups[(wsid, node.Id)] = group; return group;
        }
        var split = new SplitContainer { Dock = DockStyle.Fill, Orientation = node.Axis == "horizontal" ? Orientation.Vertical : Orientation.Horizontal, SplitterWidth = 6, BackColor = Ui.Background, Panel1MinSize = 20, Panel2MinSize = 20, Margin = Padding.Empty };
        split.Panel1.Controls.Add(BuildNode(wsid, node.First!)); split.Panel2.Controls.Add(BuildNode(wsid, node.Second!));
        var setting = false; var percent = node.FirstPercent;
        void SizeSplit()
        {
            var extent = (split.Orientation == Orientation.Vertical ? split.ClientSize.Width : split.ClientSize.Height) - split.SplitterWidth;
            if (extent < 40) return;
            setting = true; split.SplitterDistance = Math.Clamp((int)Math.Round(extent * percent / 100), 20, extent - 20); setting = false;
        }
        split.SizeChanged += (_, _) => SizeSplit();
        split.SplitterMoved += (_, _) =>
        {
            if (setting || rebuilding) return;
            var extent = (split.Orientation == Orientation.Vertical ? split.ClientSize.Width : split.ClientSize.Height) - split.SplitterWidth;
            if (extent <= 0) return;
            percent = Math.Clamp(split.SplitterDistance * 100.0 / extent, 5, 95); SaveSplit(wsid, node.Id, percent);
        };
        return split;
    }
    private void SaveSplit(string wsid, string nodeId, double percent)
    {
        var key = (wsid, nodeId);
        if (splitSaves.Remove(key, out var old)) old.Timer.Dispose();
        var timer = new System.Windows.Forms.Timer { Interval = 200 };
        timer.Tick += (_, _) => FlushSplit(key); splitSaves[key] = (timer, percent); timer.Start();
    }
    private void FlushSplit((string Workspace, string Node) key)
    {
        if (!splitSaves.Remove(key, out var save)) return; save.Timer.Dispose();
        Change(() => Store.Edit(key.Workspace, w => { var node = WorkspaceLayout.Nodes(w.Layout).FirstOrDefault(n => n.Id == key.Node); if (node is not null && node.Type == "split") node.FirstPercent = save.Percent; }));
    }
    private void FlushSplits(string wsid, bool save)
    { foreach (var key in splitSaves.Keys.Where(k => k.Workspace == wsid).ToArray()) { if (save) FlushSplit(key); else { splitSaves[key].Timer.Dispose(); splitSaves.Remove(key); } } }
    protected override bool ProcessCmdKey(ref Message message, Keys keyData)
    { if (HandleShortcut(keyData)) return true; return base.ProcessCmdKey(ref message, keyData); }
    public bool HasShortcut(Keys keyData) => keyData switch
    {
        Keys.Control | Keys.Shift | Keys.N or Keys.Control | Keys.Shift | Keys.T or Keys.Control | Keys.Shift | Keys.B or
        Keys.Control | Keys.Shift | Keys.W or Keys.Control | Keys.Shift | Keys.Q or Keys.Control | Keys.Shift | Keys.Enter or
        Keys.F2 or Keys.Control | Keys.PageDown or Keys.Control | Keys.PageUp or Keys.Control | Keys.Oemplus or
        Keys.Control | Keys.Shift | Keys.Oemplus or Keys.Control | Keys.Add or Keys.Control | Keys.OemMinus or
        Keys.Control | Keys.Subtract or Keys.Control | Keys.D0 => true,
        Keys.Escape => Active is not null && focusedGroups.ContainsKey(Active),
        Keys.Control | Keys.L => SelectedView() is BrowserPaneView,
        _ => false
    };
    public bool HandleShortcut(Keys keyData)
    {
        switch (keyData)
        {
            case Keys.Control | Keys.Shift | Keys.N: WorkspaceDialog(); return true;
            case Keys.Control | Keys.Shift | Keys.T: AddPane("terminal"); return true;
            case Keys.Control | Keys.Shift | Keys.B: AddPane("browser"); return true;
            case Keys.Control | Keys.Shift | Keys.W: if (SelectedView() is { } pane) ClosePane(pane.WorkspaceId, pane.PaneId); return true;
            case Keys.Control | Keys.Shift | Keys.Q: if (Active is { } wsid) CloseWorkspace(wsid); return true;
            case Keys.Control | Keys.Shift | Keys.Enter: ToggleFocus(); return true;
            case Keys.Escape when Active is not null && focusedGroups.ContainsKey(Active): RestoreLayout(); return true;
            case Keys.F2: if (Active is not null) WorkspaceDialog(Active); return true;
            case Keys.Control | Keys.PageDown: Cycle(1); return true;
            case Keys.Control | Keys.PageUp: Cycle(-1); return true;
            case Keys.Control | Keys.Oemplus:
            case Keys.Control | Keys.Shift | Keys.Oemplus:
            case Keys.Control | Keys.Add: ResizeText(1); return true;
            case Keys.Control | Keys.OemMinus:
            case Keys.Control | Keys.Subtract: ResizeText(-1); return true;
            case Keys.Control | Keys.D0: ResizeText(0, true); return true;
            case Keys.Control | Keys.L when SelectedView() is BrowserPaneView browser: browser.Address.Focus(); browser.Address.SelectAll(); return true;
            default: return false;
        }
    }
    private void Cycle(int direction)
    {
        var ids = Store.State.OpenWorkspaceIds; if (ids.Count == 0) return;
        var index = ids.IndexOf(Active!); SwitchWorkspace(ids[(Math.Max(0, index) + direction + ids.Count) % ids.Count]);
    }
    private void Help() => Error("Ctrl+Shift+N: new named workspace\nCtrl+Shift+T/B: new terminal/browser\nCtrl+Shift+W/Q: close pane/workspace\nCtrl+Page Up/Down: switch workspace\nF2 or double-click a workspace name: rename\nCtrl+Shift+Enter: focus pane; Escape: restore layout\nCtrl++ / Ctrl+− / Ctrl+0: terminal text size\nCtrl+Shift+C/V: terminal copy/paste\nCtrl+L: browser address\n\nUse Split or Add Pane to arrange your workspace. Drag pane tabs to a pane's edge to split or center to group. The pane menu offers equivalent move actions. Switching workspaces keeps sessions running. Closing live terminals asks first; reopening starts fresh shells. Shell profiles and start folders apply when a shell starts. Previews are read-only with scripts disabled.\n\nWindows PowerShell is included with Windows. PowerShell 7, WSL and CLI tools are installed separately. This source build has no automatic updater. See README.md beside the application.");
    public void QuitWithoutPrompt() { quitting = true; Close(); }
    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!quitting && Views.Values.OfType<TerminalPaneView>().Any(p => p.Terminal.IsRunning) && !Confirm("Quit MultiTerminal?", "Terminal sessions and child processes will stop. Your workspace configuration remains saved.")) { e.Cancel = true; return; }
        quitting = true;
        foreach (var wsid in pages.Keys.ToArray()) FlushSplits(wsid, true);
        foreach (var pane in Views.Values) pane.Dispose(); Views.Clear(); base.OnFormClosing(e);
    }
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
}

internal sealed class WorkspaceTabButton : Button
{ public WorkspaceTabButton() => SetStyle(ControlStyles.StandardClick | ControlStyles.StandardDoubleClick, true); }

internal sealed class WorkspaceNameDialog : Form
{
    private readonly TextBox name;
    public string WorkspaceName => name.Text.Trim();
    public string Folder { get; private set; } = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    public WorkspaceNameDialog(string initialName, bool create)
    {
        AutoScaleMode = AutoScaleMode.Dpi; AutoScaleDimensions = new SizeF(96, 96);
        Text = create ? "New Workspace" : "Rename Workspace"; Size = new Size(440, create ? 300 : 190); FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false; ShowInTaskbar = false; StartPosition = FormStartPosition.CenterParent; BackColor = Ui.Background; ForeColor = Ui.Foreground; Font = new Font("Segoe UI", 10);
        var form = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, Padding = new Padding(20), WrapContents = false };
        form.Controls.Add(new Label { Text = "Workspace name", AutoSize = true }); name = new TextBox { Text = initialName, Width = 380 }; form.Controls.Add(name);
        if (create)
        {
            form.Controls.Add(new Label { Text = "Start folder", AutoSize = true }); Button choose = null!;
            choose = Ui.Button(Folder, "Choose the first terminal's start folder", () =>
            {
                using var picker = new FolderBrowserDialog { InitialDirectory = Folder, Description = "Choose workspace start folder", UseDescriptionForTitle = true };
                if (picker.ShowDialog(this) != DialogResult.OK) return; Folder = picker.SelectedPath; choose.Text = Folder;
                if (name.Text.StartsWith("Workspace ")) name.Text = Path.GetFileName(Folder);
            }); choose.MaximumSize = new Size(380, 34); choose.AutoEllipsis = true; form.Controls.Add(choose);
        }
        var row = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.RightToLeft, Width = 380 };
        var accept = Ui.Button(create ? "Create Workspace" : "Save Name", "Save workspace name", () => DialogResult = DialogResult.OK, true);
        var cancel = Ui.Button("Cancel", "Cancel without saving", () => DialogResult = DialogResult.Cancel);
        name.TextChanged += (_, _) => accept.Enabled = !string.IsNullOrWhiteSpace(name.Text);
        row.Controls.Add(accept); row.Controls.Add(cancel); form.Controls.Add(row); Controls.Add(form);
        AcceptButton = accept; CancelButton = cancel; Shown += (_, _) => { name.Focus(); name.SelectAll(); };
    }
}
