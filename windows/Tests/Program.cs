using System.Text;
using System.Text.Json;
using MultiTerminal.Core;

var tests = new List<(string Name, Action Test)>();
void Test(string name, Action test) => tests.Add((name, test));
void Assert(bool result, string message = "Assertion failed") { if (!result) throw new Exception(message); }
void Reject(Action action)
{ try { action(); } catch (InvalidDataException) { return; } throw new Exception("Invalid settings were accepted"); }
void WithStore(Action<WorkspaceStore, string> test)
{
    var folder = Path.Combine(Path.GetTempPath(), "multiterminal-model-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(folder);
    try { var store = new WorkspaceStore(Path.Combine(folder, "settings.json")); var id = store.Create("Project", folder); test(store, id); }
    finally { Directory.Delete(folder, true); }
}
Test("Atomic persistence and Unicode project folder", () => WithStore((s, id) =>
{
    s.Edit(id, w => { w.Name = "مشروع · café"; w.Panes[0].DirectoryPath = "C:\\Users\\A user's project\\ملاحظات"; });
    var loaded = new WorkspaceStore(s.FilePath); Assert(loaded.Workspace(id).Name == "مشروع · café");
    Assert(loaded.Workspace(id).Panes[0].DirectoryPath.EndsWith("ملاحظات"));
    Assert(!Directory.EnumerateFiles(Path.GetDirectoryName(s.FilePath)!, ".workspaces-*.tmp").Any());
}));
Test("Failed writes preserve in-memory state and previous file", () => WithStore((s, id) =>
{
    var original = File.ReadAllBytes(s.FilePath); var state = JsonSerializer.Serialize(s.State);
    var backup = s.FilePath + ".original"; File.Move(s.FilePath, backup); Directory.CreateDirectory(s.FilePath);
    try { s.Edit(id, w => w.Name = "Must not persist"); throw new Exception("Write unexpectedly succeeded"); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    Assert(JsonSerializer.Serialize(s.State) == state); Assert(File.ReadAllBytes(backup).SequenceEqual(original));
    Directory.Delete(s.FilePath); File.Move(backup, s.FilePath);
}));
Test("Corrupt settings are preserved", () => WithStore((s, _) =>
{
    foreach (var content in new[] { "{ broken", "{}", "[]", "null", "{\"schemaVersion\":1,\"workspaces\":null,\"openWorkspaceIds\":[],\"activeWorkspaceId\":null,\"globalTheme\":\"midnight\"}" })
    {
        File.WriteAllText(s.FilePath, content); Reject(() => new WorkspaceStore(s.FilePath)); Assert(File.ReadAllText(s.FilePath) == content);
    }
}));
Test("Workspace close, reopen and delete", () => WithStore((s, id) =>
{
    s.Close(id); Assert(s.State.ActiveWorkspaceId is null && s.State.Workspaces.Count == 1);
    s.Open(id); Assert(s.State.ActiveWorkspaceId == id); s.Close(id, true); Assert(s.State.Workspaces.Count == 0);
}));
Test("Nested split collapse and empty workspace recovery", () => WithStore((s, id) =>
{
    var first = s.Workspace(id).Panes[0].Id; var second = new PaneModel(); s.Add(id, second);
    var third = new PaneModel(); s.Add(id, third, edge: "bottom"); Assert(Layout.Groups(s.Workspace(id).Layout).Count() == 3);
    s.Remove(id, third.Id); Assert(Layout.Groups(s.Workspace(id).Layout).Count() == 2);
    s.Remove(id, second.Id); s.Remove(id, first); Assert(s.Workspace(id).Layout is null);
    s.Add(id, new PaneModel()); Assert(Layout.Groups(s.Workspace(id).Layout).Count() == 1);
}));
Test("Tab close preserves group focus", () => WithStore((s, id) =>
{
    var second = new PaneModel(); s.Add(id, second); var group = s.Workspace(id).FocusedGroupId;
    var third = new PaneModel(); s.Add(id, third, asTab: true); s.Remove(id, third.Id);
    Assert(s.Workspace(id).FocusedGroupId == group); Assert(Layout.Groups(s.Workspace(id).Layout).Single(g => g.Id == group).SelectedPaneId == second.Id);
}));
Test("Docking and reordering preserve all pane IDs", () => WithStore((s, id) =>
{
    var first = s.Workspace(id).Panes[0].Id; var second = new PaneModel(); s.Add(id, second);
    var group = s.Workspace(id).FocusedGroupId!; s.Dock(id, first, group); s.Dock(id, first, group, before: second.Id);
    Assert(Layout.Groups(s.Workspace(id).Layout).Single().PaneIds.SequenceEqual(new[] { first, second.Id }));
    s.Dock(id, first, group, "left"); Assert(Layout.Groups(s.Workspace(id).Layout).Count() == 2);
    Assert(s.Workspace(id).Panes.Count == 2);
}));
Test("Invalid transactions leave saved state untouched", () => WithStore((s, id) =>
{
    var bytes = File.ReadAllBytes(s.FilePath); Reject(() => s.Edit(id, w => w.Id = "../escape"));
    Reject(() => s.Edit(id, w => w.Layout!.PaneIds.Add(w.Panes[0].Id)));
    Reject(() => s.Edit(id, w => w.Panes = null!)); Reject(() => s.Edit(id, w => w.Layout!.PaneIds = null!));
    Assert(File.ReadAllBytes(s.FilePath).SequenceEqual(bytes)); Assert(s.Workspace(id).Id == id);
}));
Test("Theme, font and shell preference bounds", () => WithStore((s, _) =>
{
    s.Commit(state => { state.GlobalTheme = "amber"; state.TerminalFontSize = 15; state.DefaultShell = "cmd"; });
    var saved = new WorkspaceStore(s.FilePath); Assert(saved.State.TerminalFontSize == 15 && saved.State.DefaultShell == "cmd");
    Reject(() => s.Commit(state => state.TerminalFontSize = 25)); Reject(() => s.Commit(state => state.TerminalFontSize = 7));
    Reject(() => s.Commit(state => state.DefaultShell = "arbitrary command")); Reject(() => s.Commit(state => state.GlobalTheme = "unknown"));
}));
Test("Split percentages reject NaN and invalid ranges", () => WithStore((s, id) =>
{
    s.Add(id, new PaneModel());
    foreach (var value in new[] { 0.0, 100, double.NaN, double.PositiveInfinity }) Reject(() => s.Edit(id, w => w.Layout!.FirstPercent = value));
}));
Test("Open workspace and selected pane references are validated", () => WithStore((s, id) =>
{
    Reject(() => s.Commit(state => state.OpenWorkspaceIds.Add(Guid.NewGuid().ToString())));
    Reject(() => s.Commit(state => state.OpenWorkspaceIds.Add(id)));
    Reject(() => s.Edit(id, w => w.Layout!.SelectedPaneId = Guid.NewGuid().ToString()));
}));
Test("HTTP addresses and localhost ports normalize correctly", () =>
{
    Assert(WorkspaceStore.NormalizeUrl("localhost:5173/a") == "http://localhost:5173/a");
    Assert(WorkspaceStore.NormalizeUrl("[::1]:8080") == "http://[::1]:8080/");
    Assert(WorkspaceStore.NormalizeUrl("example.com") == "https://example.com/");
    Assert(WorkspaceStore.NormalizeUrl("localhost.example.com").StartsWith("https://"));
});
Test("Unsafe and malformed browser schemes are rejected", () =>
{
    foreach (var url in new[] { "file:///C:/secret", "javascript://example.com", "http://localhost:99999", "https://example.com/a\nb" }) Reject(() => WorkspaceStore.NormalizeUrl(url));
});
Test("Windows executable argument quoting", () =>
{
    Assert(WindowsCommandLine.Quote("C:\\Program Files\\PowerShell\\pwsh.exe") == "\"C:\\Program Files\\PowerShell\\pwsh.exe\"");
    Assert(WindowsCommandLine.Quote("C:\\folder\\") == "\"C:\\folder\\\\\"");
    Assert(WindowsCommandLine.Quote("a\"b") == "\"a\\\"b\"");
});
Test("Terminal ANSI cursor movement and erase", () =>
{
    var engine = new TerminalEngine(); engine.Push(Encoding.UTF8.GetBytes("hello\r\nworld\x1b[1;1HOK\x1b[K"));
    Assert(engine.Text().StartsWith("OK\nworld"));
});
Test("Terminal colors and truecolor attributes", () =>
{
    var engine = new TerminalEngine(); engine.Push(Encoding.UTF8.GetBytes("\x1b[31mR\x1b[38;2;18;52;86mT"));
    var spans = engine.Terminal.ViewPort.GetPageSpans(0, 1)[0].Spans;
    Assert(spans.Any(span => span.ForgroundColor.Equals("#123456", StringComparison.OrdinalIgnoreCase)));
});
Test("Split UTF-8 output preserves characters", () =>
{
    var engine = new TerminalEngine(); foreach (var value in Encoding.UTF8.GetBytes("café Ω")) engine.Push([value]);
    Assert(engine.Text().StartsWith("café Ω"));
});
Test("Alternate screen restores the original buffer", () =>
{
    var engine = new TerminalEngine(); engine.Push(Encoding.UTF8.GetBytes("main\x1b[?1049h\x1b[2J\x1b[Halternate"));
    Assert(engine.Text().Contains("alternate")); engine.Push(Encoding.UTF8.GetBytes("\x1b[?1049l")); Assert(engine.Text().Contains("main"));
});
Test("Bracketed paste and cursor responses reach the process", () =>
{
    var engine = new TerminalEngine(); var output = new List<byte>(); engine.Send += data => output.AddRange(data);
    engine.Push(Encoding.UTF8.GetBytes("\x1b[?2004h")); engine.Paste("hello");
    Assert(Encoding.UTF8.GetString(output.ToArray()) == "\x1b[200~hello\x1b[201~");
    output.Clear(); engine.Push(Encoding.UTF8.GetBytes("\x1b[6n")); Assert(Encoding.UTF8.GetString(output.ToArray()).Contains("[1;1R"));
});
Test("History is bounded across resize and output", () =>
{
    var engine = new TerminalEngine(); engine.Terminal.MaximumHistoryLines = 20; engine.Resize(40, 5);
    engine.Push(Encoding.UTF8.GetBytes(string.Join("\r\n", Enumerable.Range(0, 100).Select(n => "line " + n))));
    Assert(engine.Terminal.ViewPort.TopRow <= 20); Assert(engine.Text().Contains("line 99"));
});
var failures = 0;
foreach (var (name, test) in tests)
{
    try { test(); Console.WriteLine("PASS: " + name); }
    catch (Exception e) { failures++; Console.WriteLine("FAIL: " + name + "\n" + e); }
}
Console.WriteLine($"{tests.Count - failures}/{tests.Count} checks passed.");
return failures == 0 ? 0 : 1;
