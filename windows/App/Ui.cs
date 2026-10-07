using System.Diagnostics;
using Microsoft.Web.WebView2.Core;

namespace MultiTerminal;

internal static class Ui
{
    public static readonly Color Background = Color.FromArgb(15, 21, 32);
    public static readonly Color Header = Color.FromArgb(24, 34, 49);
    public static readonly Color Foreground = Color.FromArgb(220, 229, 245);
    public static readonly Color Accent = Color.FromArgb(37, 58, 88);
    public static readonly ToolTip Tips = new() { AutoPopDelay = 10000 };
    public static Button Button(string text, string tip, Action action, bool primary = false)
    {
        var b = new Button { Text = text, AutoSize = true, MinimumSize = new Size(30, 30), FlatStyle = FlatStyle.Flat, BackColor = primary ? Color.FromArgb(34, 93, 171) : Header, ForeColor = Foreground, Padding = new Padding(5, 0, 5, 0), Margin = new Padding(2), AccessibleName = tip };
        b.FlatAppearance.BorderSize = 0;
        Tips.SetToolTip(b, tip); b.Click += (_, _) => action(); return b;
    }
    public static ContextMenuStrip Menu()
    {
        return new ContextMenuStrip { BackColor = Header, ForeColor = Foreground, ShowImageMargin = false, Font = new Font("Segoe UI", 10) };
    }
    public static void Item(ToolStripDropDown menu, string label, Action action, bool check = false)
    {
        var item = new ToolStripMenuItem(label) { Checked = check, ForeColor = Foreground, BackColor = Header };
        item.Click += (_, _) => action(); menu.Items.Add(item);
    }
    public static void Open(string uriOrPath) => Process.Start(new ProcessStartInfo(uriOrPath) { UseShellExecute = true });
    public static void OnUi(Control control, Action action)
    {
        if (control.IsDisposed || control.Disposing || !control.IsHandleCreated) return;
        try { if (control.InvokeRequired) Post(control, action); else action(); }
        catch (InvalidOperationException) { }
    }
    public static void Post(Control control, Action action)
    {
        if (control.IsDisposed || control.Disposing || !control.IsHandleCreated) return;
        try { control.BeginInvoke((Action)(() => { if (!control.IsDisposed && !control.Disposing) action(); })); }
        catch (InvalidOperationException) { }
    }
}

internal static class AppPaths
{
    public static string Root { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MultiTerminal Source");
    public static string Settings => Path.Combine(Root, "workspaces.json");
    public static string Browser(string workspaceId) => Path.Combine(Root, "Browsers", workspaceId);
}

internal sealed class BrowserEnvironments
{
    private readonly Dictionary<string, Task<CoreWebView2Environment>> environments = [];
    public Task<CoreWebView2Environment> Get(string workspaceId)
    {
        if (!environments.TryGetValue(workspaceId, out var environment) || environment.IsFaulted || environment.IsCanceled)
        {
            environment = CoreWebView2Environment.CreateAsync(userDataFolder: AppPaths.Browser(workspaceId));
            environments[workspaceId] = environment;
        }
        return environment;
    }
    public void Forget(string workspaceId) => environments.Remove(workspaceId);
}
