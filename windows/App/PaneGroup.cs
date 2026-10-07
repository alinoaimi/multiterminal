using MultiTerminal.Core;
using WorkspaceLayout = MultiTerminal.Core.Layout;

namespace MultiTerminal;

internal sealed class PaneGroup : UserControl
{
    private const string DragFormat = "MultiTerminal.Pane";
    private readonly MainForm owner;
    private readonly string wsid, gid;
    private readonly Panel content = new() { Dock = DockStyle.Fill, Margin = Padding.Empty };
    private readonly Dictionary<string, Button> tabs = [];
    private readonly Button focus;
    private LayoutNode Model => WorkspaceLayout.Groups(owner.Store.Workspace(wsid).Layout).Single(g => g.Id == gid);

    public PaneGroup(MainForm owner, string wsid, string gid)
    {
        this.owner = owner; this.wsid = wsid; this.gid = gid;
        Dock = DockStyle.Fill; Padding = new Padding(1); BackColor = Ui.Header; Margin = Padding.Empty;
        var body = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, Margin = Padding.Empty };
        body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); body.RowStyles.Add(new RowStyle(SizeType.Absolute, 38)); body.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var header = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, BackColor = Ui.Header, Margin = Padding.Empty };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var strip = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoScroll = true, WrapContents = false, Margin = Padding.Empty, Padding = new Padding(2) };
        foreach (var pid in Model.PaneIds)
        {
            var model = owner.Store.Pane(wsid, pid);
            var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(1) };
            var tab = Ui.Button(MainForm.PaneTitle(model), model.Kind + ": " + PaneLocation(model) + "\nDrag to an edge to split or the center to group.", () => owner.SelectPane(wsid, pid));
            tab.MaximumSize = new Size(160, 30); tab.AutoEllipsis = true;
            Point press = Point.Empty;
            tab.MouseDown += (_, e) => { if (e.Button == MouseButtons.Left) press = e.Location; };
            tab.MouseMove += (_, e) =>
            {
                if (e.Button != MouseButtons.Left || Math.Abs(e.X - press.X) < SystemInformation.DragSize.Width && Math.Abs(e.Y - press.Y) < SystemInformation.DragSize.Height) return;
                var data = new DataObject(); data.SetData(DragFormat, wsid + ":" + pid); tab.DoDragDrop(data, DragDropEffects.Move);
            };
            tab.AllowDrop = true;
            tab.DragEnter += (_, e) => e.Effect = Valid(e.Data) ? DragDropEffects.Move : DragDropEffects.None;
            tab.DragDrop += (_, e) => { var id = PaneId(e.Data); if (id is not null) owner.DockPane(wsid, id, gid, before: pid); };
            tabs[pid] = tab; row.Controls.Add(tab); row.Controls.Add(Ui.Button("×", "Close pane", () => owner.ClosePane(wsid, pid))); strip.Controls.Add(row);
            var view = owner.Views[(wsid, pid)]; content.Controls.Add(view);
        }
        var actions = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = Padding.Empty };
        Button add = null!, split = null!, more = null!;
        add = Ui.Button("+", "Add a pane to this group", () => owner.ShowAdd(add, wsid, gid));
        split = Ui.Button("Split ▾", "Create a terminal beside or below this pane", () => owner.ShowSplit(split, wsid, gid));
        focus = Ui.Button("⤢", "Focus or restore this pane · Ctrl+Shift+Enter", () => owner.ToggleFocus(wsid, gid));
        more = Ui.Button("⋮", "Folder, clipboard, shell, theme and move actions", () => owner.ShowPaneMenu(more, wsid, gid));
        actions.Controls.Add(add); actions.Controls.Add(split); actions.Controls.Add(focus); actions.Controls.Add(more);
        header.Controls.Add(strip, 0, 0); header.Controls.Add(actions, 1, 0);
        body.Controls.Add(header, 0, 0); body.Controls.Add(content, 0, 1); Controls.Add(body);
        AllowDrop = true;
        DragEnter += (_, e) => e.Effect = Valid(e.Data) ? DragDropEffects.Move : DragDropEffects.None;
        DragOver += (_, e) => { e.Effect = Valid(e.Data) ? DragDropEffects.Move : DragDropEffects.None; if (e.Effect != DragDropEffects.None) BackColor = Color.FromArgb(130, 170, 255); };
        DragLeave += (_, _) => UpdateSelection();
        DragDrop += (_, e) =>
        {
            var id = PaneId(e.Data); if (id is null) return;
            var point = PointToClient(new Point(e.X, e.Y));
            var edge = point.X < Width * .22 ? "left" : point.X > Width * .78 ? "right" : point.Y < Height * .22 ? "top" : point.Y > Height * .78 ? "bottom" : null;
            owner.DockPane(wsid, id, gid, edge);
        };
        UpdateSelection();
    }
    private static string PaneLocation(PaneModel model) => model.Kind switch { "terminal" => model.DirectoryPath, "browser" => model.Url, _ => model.Path };
    private string? PaneId(IDataObject? data)
    {
        var payload = data?.GetData(DragFormat) as string;
        if (payload is null) return null;
        var parts = payload.Split(':');
        return parts.Length == 2 && parts[0] == wsid && owner.Views.ContainsKey((wsid, parts[1])) ? parts[1] : null;
    }
    private bool Valid(IDataObject? data) => PaneId(data) is not null;
    public void UpdateSelection()
    {
        var selected = Model.SelectedPaneId;
        foreach (var (pid, button) in tabs)
        {
            button.BackColor = pid == selected ? Ui.Accent : Ui.Header;
            var view = owner.Views[(wsid, pid)]; view.Visible = pid == selected; if (pid == selected) view.BringToFront();
        }
        BackColor = owner.Store.Workspace(wsid).FocusedGroupId == gid ? Color.FromArgb(123, 158, 204) : Color.FromArgb(40, 54, 76);
        focus.Enabled = WorkspaceLayout.Groups(owner.Store.Workspace(wsid).Layout).Count() > 1;
    }
    public void UpdateTitles()
    {
        foreach (var (pid, button) in tabs)
        { var model = owner.Store.Pane(wsid, pid); button.Text = MainForm.PaneTitle(model); Ui.Tips.SetToolTip(button, model.Kind + ": " + PaneLocation(model) + "\nDrag to an edge to split or center to group."); }
    }
}
