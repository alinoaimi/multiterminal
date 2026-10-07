using System.Text.Json;
using System.Text.Json.Serialization;

namespace MultiTerminal.Core;

public sealed class PaneModel
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Kind { get; set; } = "terminal";
    public string DirectoryPath { get; set; } = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    public string? ThemeOverride { get; set; }
    public string? Shell { get; set; }
    public string Url { get; set; } = "";
    public string Path { get; set; } = "";
}

public sealed class LayoutNode
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Type { get; set; } = "group";
    public List<string> PaneIds { get; set; } = [];
    public string? SelectedPaneId { get; set; }
    public string Axis { get; set; } = "horizontal";
    public double FirstPercent { get; set; } = 50;
    public LayoutNode? First { get; set; }
    public LayoutNode? Second { get; set; }
    public static LayoutNode Group(string paneId) => new() { PaneIds = [paneId], SelectedPaneId = paneId };
}

public sealed class WorkspaceModel
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "Workspace";
    public List<PaneModel> Panes { get; set; } = [];
    public LayoutNode? Layout { get; set; }
    public string? FocusedGroupId { get; set; }
}

public sealed class WorkspaceState
{
    [JsonRequired]
    public int SchemaVersion { get; set; } = 1;
    [JsonRequired]
    public List<WorkspaceModel> Workspaces { get; set; } = [];
    [JsonRequired]
    public List<string> OpenWorkspaceIds { get; set; } = [];
    [JsonRequired]
    public string? ActiveWorkspaceId { get; set; }
    [JsonRequired]
    public string GlobalTheme { get; set; } = "midnight";
    public int TerminalFontSize { get; set; } = 11;
    public string DefaultShell { get; set; } = "powershell";
}

public static class Layout
{
    public static IEnumerable<LayoutNode> Nodes(LayoutNode? node)
    {
        if (node is null) yield break;
        yield return node;
        if (node.Type != "split") yield break;
        foreach (var child in Nodes(node.First)) yield return child;
        foreach (var child in Nodes(node.Second)) yield return child;
    }
    public static IEnumerable<LayoutNode> Groups(LayoutNode? node) => Nodes(node).Where(n => n.Type == "group");
    public static LayoutNode Replace(LayoutNode node, string id, LayoutNode replacement)
    {
        if (node.Id == id) return replacement;
        if (node.Type == "split")
        {
            node.First = Replace(node.First!, id, replacement);
            node.Second = Replace(node.Second!, id, replacement);
        }
        return node;
    }
    public static LayoutNode? Remove(LayoutNode? node, string paneId)
    {
        if (node is null) return null;
        if (node.Type == "group")
        {
            node.PaneIds.Remove(paneId);
            if (node.PaneIds.Count == 0) return null;
            if (!node.PaneIds.Contains(node.SelectedPaneId!)) node.SelectedPaneId = node.PaneIds[0];
        }
        else
        {
            node.First = Remove(node.First, paneId);
            node.Second = Remove(node.Second, paneId);
            if (node.First is null) return node.Second;
            if (node.Second is null) return node.First;
        }
        return node;
    }
    public static LayoutNode Split(LayoutNode existing, LayoutNode incoming, string edge)
    {
        if (!new[] { "left", "right", "top", "bottom" }.Contains(edge)) throw new InvalidDataException("Invalid split edge.");
        var incomingFirst = edge is "left" or "top";
        return new LayoutNode { Type = "split", Axis = edge is "left" or "right" ? "horizontal" : "vertical", First = incomingFirst ? incoming : existing, Second = incomingFirst ? existing : incoming };
    }
}

public sealed class WorkspaceStore
{
    public static readonly string[] Themes = ["midnight", "highContrast", "amber"];
    public static readonly string[] Shells = ["powershell", "pwsh", "cmd", "wsl"];
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true, MaxDepth = 192 };
    public string FilePath { get; }
    public WorkspaceState State { get; private set; } = new();

    public WorkspaceStore(string path)
    {
        FilePath = System.IO.Path.GetFullPath(path);
        if (!File.Exists(FilePath)) return;
        try
        {
            if (new FileInfo(FilePath).Length > 10 * 1024 * 1024) throw new InvalidDataException("Settings exceed 10 MB.");
            var state = JsonSerializer.Deserialize<WorkspaceState>(File.ReadAllText(FilePath), Json) ?? throw new InvalidDataException("Empty settings.");
            Validate(state);
            State = state;
        }
        catch (Exception e) when (e is IOException or JsonException or InvalidDataException or ArgumentException or NullReferenceException)
        {
            throw new InvalidDataException($"Could not read {FilePath}. Your saved file has been preserved.\n{e.Message}", e);
        }
    }
    public WorkspaceModel Workspace(string id) => State.Workspaces.Single(w => w.Id == id);
    public PaneModel Pane(string wsid, string paneId) => Workspace(wsid).Panes.Single(p => p.Id == paneId);

    public void Commit(Action<WorkspaceState> change)
    {
        var candidate = JsonSerializer.Deserialize<WorkspaceState>(JsonSerializer.Serialize(State, Json), Json)!;
        change(candidate);
        Validate(candidate);
        var directory = System.IO.Path.GetDirectoryName(FilePath)!;
        Directory.CreateDirectory(directory);
        var temporary = System.IO.Path.Combine(directory, $".workspaces-{Guid.NewGuid():N}.tmp");
        try
        {
            using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(file, candidate, Json);
                file.Flush(true);
            }
            if (File.Exists(FilePath)) File.Replace(temporary, FilePath, null);
            else File.Move(temporary, FilePath);
            State = candidate;
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public void Edit(string id, Action<WorkspaceModel> change) => Commit(s => change(s.Workspaces.Single(w => w.Id == id)));
    public string Create(string? name = null, string? folder = null)
    {
        var pane = new PaneModel { DirectoryPath = folder ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) };
        var group = LayoutNode.Group(pane.Id);
        var ws = new WorkspaceModel { Name = name ?? $"Workspace {State.Workspaces.Count + 1}", Panes = [pane], Layout = group, FocusedGroupId = group.Id };
        Commit(s => { s.Workspaces.Add(ws); s.OpenWorkspaceIds.Add(ws.Id); s.ActiveWorkspaceId = ws.Id; });
        return ws.Id;
    }
    public void Open(string id)
    {
        Workspace(id);
        Commit(s => { if (!s.OpenWorkspaceIds.Contains(id)) s.OpenWorkspaceIds.Add(id); s.ActiveWorkspaceId = id; });
    }
    public void Close(string id, bool delete = false) => Commit(s =>
    {
        s.OpenWorkspaceIds.Remove(id);
        if (delete) s.Workspaces.RemoveAll(w => w.Id == id);
        if (s.ActiveWorkspaceId == id) s.ActiveWorkspaceId = s.OpenWorkspaceIds.FirstOrDefault();
    });
    public void Add(string wsid, PaneModel pane, string? target = null, string edge = "right", bool asTab = false) => Edit(wsid, ws =>
    {
        if (ws.Panes.Count >= 256) throw new InvalidDataException("A workspace can contain up to 256 panes.");
        var dest = Layout.Groups(ws.Layout).FirstOrDefault(g => g.Id == (target ?? ws.FocusedGroupId)) ?? Layout.Groups(ws.Layout).FirstOrDefault();
        ws.Panes.Add(pane);
        if (asTab && dest is not null)
        {
            dest.PaneIds.Add(pane.Id); dest.SelectedPaneId = pane.Id; ws.FocusedGroupId = dest.Id;
        }
        else
        {
            var incoming = LayoutNode.Group(pane.Id);
            ws.Layout = dest is null ? incoming : Layout.Replace(ws.Layout!, dest.Id, Layout.Split(dest, incoming, edge));
            ws.FocusedGroupId = incoming.Id;
        }
    });
    public void Remove(string wsid, string paneId) => Edit(wsid, ws =>
    {
        ws.Panes.RemoveAll(p => p.Id == paneId); ws.Layout = Layout.Remove(ws.Layout, paneId);
        var groups = Layout.Groups(ws.Layout).ToArray();
        if (!groups.Any(g => g.Id == ws.FocusedGroupId)) ws.FocusedGroupId = groups.FirstOrDefault()?.Id;
    });
    public void Select(string wsid, string paneId) => Edit(wsid, ws =>
    {
        var dest = Layout.Groups(ws.Layout).Single(g => g.PaneIds.Contains(paneId));
        dest.SelectedPaneId = paneId; ws.FocusedGroupId = dest.Id;
    });
    public void Dock(string wsid, string paneId, string target, string? edge = null, string? before = null) => Edit(wsid, ws =>
    {
        var source = Layout.Groups(ws.Layout).Single(g => g.PaneIds.Contains(paneId));
        if (source.Id == target && (source.PaneIds.Count == 1 || before == paneId)) return;
        var remainder = Layout.Remove(ws.Layout, paneId)!;
        var dest = Layout.Groups(remainder).Single(g => g.Id == target);
        if (edge is not null)
        {
            var incoming = LayoutNode.Group(paneId);
            ws.Layout = Layout.Replace(remainder, target, Layout.Split(dest, incoming, edge)); ws.FocusedGroupId = incoming.Id;
        }
        else
        {
            var index = before is not null ? dest.PaneIds.IndexOf(before) : -1;
            dest.PaneIds.Insert(index < 0 ? dest.PaneIds.Count : index, paneId); dest.SelectedPaneId = paneId;
            ws.Layout = remainder; ws.FocusedGroupId = dest.Id;
        }
    });
    public static void Validate(WorkspaceState s)
    {
        if (s.Workspaces is null || s.OpenWorkspaceIds is null || s.SchemaVersion != 1 || !Themes.Contains(s.GlobalTheme) || !Shells.Contains(s.DefaultShell) || s.TerminalFontSize is < 8 or > 24)
            throw new InvalidDataException("Unsupported workspace settings.");
        var workspaceIds = new HashSet<string>();
        foreach (var w in s.Workspaces)
        {
            if (w is null || w.Panes is null) throw new InvalidDataException("Invalid workspace.");
            ValidateId(w.Id);
            if (!workspaceIds.Add(w.Id) || string.IsNullOrWhiteSpace(w.Name) || w.Panes.Count > 256) throw new InvalidDataException("Invalid workspace.");
            var paneIds = new HashSet<string>();
            foreach (var p in w.Panes)
            {
                if (p is null) throw new InvalidDataException("Invalid pane.");
                ValidateId(p.Id);
                if (!paneIds.Add(p.Id) || p.Kind is not ("terminal" or "browser" or "filePreview") || p.DirectoryPath is null || p.Path is null || p.Url is null ||
                    (p.ThemeOverride is not null && !Themes.Contains(p.ThemeOverride)) || (p.Shell is not null && !Shells.Contains(p.Shell))) throw new InvalidDataException("Invalid pane.");
                if (p.Kind == "browser" && p.Url.Length > 0) NormalizeUrl(p.Url);
            }
            var seenNodes = new HashSet<string>(); var layoutPanes = new HashSet<string>(); var groupIds = new HashSet<string>();
            void Check(LayoutNode n, int depth)
            {
                ValidateId(n.Id);
                if (depth > 64 || !seenNodes.Add(n.Id)) throw new InvalidDataException("Invalid layout nesting.");
                if (n.Type == "group")
                {
                    groupIds.Add(n.Id);
                    if (n.PaneIds is null || n.PaneIds.Count == 0 || !n.PaneIds.Contains(n.SelectedPaneId!)) throw new InvalidDataException("Invalid selected tab.");
                    foreach (var id in n.PaneIds) if (!layoutPanes.Add(id)) throw new InvalidDataException("Pane appears twice in the layout.");
                }
                else if (n.Type == "split" && n.Axis is "horizontal" or "vertical" && double.IsFinite(n.FirstPercent) && n.FirstPercent is > 0 and < 100 && n.First is not null && n.Second is not null)
                { Check(n.First, depth + 1); Check(n.Second, depth + 1); }
                else throw new InvalidDataException("Invalid layout node.");
            }
            if (w.Layout is not null) Check(w.Layout, 0);
            if (!layoutPanes.SetEquals(paneIds) || (w.FocusedGroupId is not null && !groupIds.Contains(w.FocusedGroupId))) throw new InvalidDataException("Layout does not match its panes.");
        }
        if (s.OpenWorkspaceIds.Distinct().Count() != s.OpenWorkspaceIds.Count || s.OpenWorkspaceIds.Any(id => !workspaceIds.Contains(id)) ||
            (s.ActiveWorkspaceId is not null && !s.OpenWorkspaceIds.Contains(s.ActiveWorkspaceId))) throw new InvalidDataException("Invalid open workspace list.");
    }
    public static void ValidateId(string id)
    {
        if (!Guid.TryParseExact(id, "D", out var guid) || guid.ToString() != id) throw new InvalidDataException("Invalid workspace identifier.");
    }
    public static string NormalizeUrl(string value)
    {
        value = value.Trim();
        if (value.Length == 0) return "";
        if (value.Any(char.IsControl)) throw new InvalidDataException("The address contains invalid characters.");
        if (!value.Contains("://"))
        {
            var local = Uri.TryCreate("http://" + value, UriKind.Absolute, out var candidate) && candidate.IsLoopback;
            value = (local ? "http://" : "https://") + value;
        }
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https") || string.IsNullOrEmpty(uri.Host))
            throw new InvalidDataException("Enter an HTTP or HTTPS address, such as localhost:5173.");
        return uri.AbsoluteUri;
    }
}
