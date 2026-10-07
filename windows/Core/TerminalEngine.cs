using System.Text;
using VtNetCore.VirtualTerminal;
using VtNetCore.XTermParser;

namespace MultiTerminal.Core;

public sealed class TerminalEngine
{
    public object Gate { get; } = new();
    public VirtualTerminalController Terminal { get; } = new() { MaximumHistoryLines = 10000 };
    private readonly DataConsumer parser;
    public event Action<byte[]>? Send;
    public TerminalEngine()
    {
        parser = new DataConsumer(Terminal);
        Terminal.SendData += (_, e) => Send?.Invoke(e.Data);
        Terminal.ResizeView(80, 24);
    }
    public void Push(byte[] bytes) { lock (Gate) parser.Push(bytes); }
    public void Resize(int columns, int rows) { lock (Gate) Terminal.ResizeView(columns, rows); }
    public void Paste(string text)
    {
        lock (Gate)
        {
            // VtNetCore 1.0.30's Paste helper emits malformed delimiters.
            // Keep its mode tracking and send the standard xterm framing here.
            var value = Terminal.BracketedPasteMode ? "\x1b[200~" + text + "\x1b[201~" : text;
            Send?.Invoke(Encoding.UTF8.GetBytes(value));
        }
    }
    public string Text()
    {
        lock (Gate) return string.Join("\n", Terminal.ViewPort.GetPageSpans(0, -1).Select(row => string.Concat(row.Spans.Select(span => span.Text)).TrimEnd()));
    }
}

public static class WindowsCommandLine
{
    public static string Quote(string value)
    {
        var result = new StringBuilder("\""); var slashes = 0;
        foreach (var c in value)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') result.Append('\\', slashes * 2 + 1);
            else result.Append('\\', slashes);
            result.Append(c); slashes = 0;
        }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }
}
