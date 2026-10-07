using System.Globalization;
using System.ComponentModel;
using System.Text;
using MultiTerminal.Core;
using VtNetCore.VirtualTerminal;
using VtNetCore.VirtualTerminal.Enums;

namespace MultiTerminal;

/// <summary>Native GDI terminal renderer and input control; no web terminal.</summary>
internal sealed class TerminalSurface : Control
{
    private readonly System.Windows.Forms.Timer repaint = new() { Interval = 33 };
    private readonly Action focused;
    private int dirty = 1, scrollOffset, columns = 80, rows = 24;
    private float cellWidth = 9, cellHeight = 19;
    private Point? selectionStart, selectionEnd;
    private string theme = "midnight";
    public TerminalEngine Engine { get; private set; } = new();
    public ConPtySession? Session { get; private set; }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public string DirectoryPath { get; set; } = "";
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public string Shell { get; set; } = "powershell";
    public event Action<string, bool>? StatusChanged;
    private bool started;
    private char? highSurrogate;

    public TerminalSurface(Action focused)
    {
        this.focused = focused;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.Selectable, true);
        Dock = DockStyle.Fill; TabStop = true; BackColor = Ui.Background;
        AccessibleName = "Terminal"; AccessibleRole = AccessibleRole.Text;
        Font = new Font("Consolas", 11);
        repaint.Tick += (_, _) => { if (Visible && (Interlocked.Exchange(ref dirty, 0) != 0 || Focused)) Invalidate(); };
        repaint.Start();
        var menu = Ui.Menu();
        Ui.Item(menu, "Copy\tCtrl+Shift+C", Copy); Ui.Item(menu, "Paste\tCtrl+Shift+V", Paste);
        ContextMenuStrip = menu;
    }
    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        if (!started) { started = true; BeginInvoke(Start); }
    }
    public void Start()
    {
        if (IsDisposed) return;
        Session?.Dispose();
        Engine = new TerminalEngine(); selectionStart = selectionEnd = null; scrollOffset = 0;
        var engine = Engine;
        var session = new ConPtySession(); Session = session;
        engine.Send += session.Send;
        session.Output += bytes =>
        {
            if (!ReferenceEquals(Session, session) || IsDisposed) return;
            lock (engine.Gate)
            {
                var before = engine.Terminal.ViewPort.TopRow;
                engine.Push(bytes);
                if (scrollOffset > 0) scrollOffset = Math.Min(engine.Terminal.ViewPort.TopRow, scrollOffset + Math.Max(0, engine.Terminal.ViewPort.TopRow - before));
            }
            Interlocked.Exchange(ref dirty, 1);
        };
        session.ChildExited += code => Ui.OnUi(this, () => { if (ReferenceEquals(Session, session)) StatusChanged?.Invoke($"Shell exited (status {code}).", true); });
        session.Failed += message => Ui.OnUi(this, () => { if (ReferenceEquals(Session, session)) StatusChanged?.Invoke(message, true); });
        try
        {
            Geometry(); engine.Resize(columns, rows);
            var directory = Directory.Exists(DirectoryPath) ? DirectoryPath : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            session.Start(Shell, directory, columns, rows);
            StatusChanged?.Invoke(directory == DirectoryPath ? "" : "Start folder is unavailable. Using your home folder.", false);
        }
        catch (Exception e) { session.Dispose(); StatusChanged?.Invoke(e.Message, true); }
        dirty = 1; Invalidate();
    }
    public bool IsRunning => Session is { ProcessId: > 0, Exited: false };
    public void Apply(string selectedTheme, int size)
    {
        theme = selectedTheme;
        if ((int)Font.SizeInPoints != size)
        {
            var old = Font; Font = new Font("Consolas", size); old.Dispose();
        }
        BackColor = theme == "amber" ? Color.FromArgb(32, 23, 11) : theme == "highContrast" ? Color.Black : Ui.Background;
        Geometry(); dirty = 1; Invalidate();
    }
    private void Geometry()
    {
        if (!IsHandleCreated || ClientSize.Width < 32 || ClientSize.Height < 32) return;
        using var graphics = CreateGraphics();
        var width = TextRenderer.MeasureText(graphics, "MMMMMMMMMM", Font, Size.Empty, TextFormatFlags.NoPadding).Width / 10f;
        cellWidth = Math.Max(1, width); cellHeight = Math.Max(1, Font.GetHeight(graphics) + 2);
        var newColumns = Math.Clamp((int)((ClientSize.Width - 20) / cellWidth), 2, 500);
        var newRows = Math.Clamp((int)((ClientSize.Height - 16) / cellHeight), 2, 300);
        if (newColumns == columns && newRows == rows) return;
        columns = newColumns; rows = newRows; Engine.Resize(columns, rows);
        try { Session?.Resize(columns, rows); }
        catch (Exception e) { StatusChanged?.Invoke(e.Message, false); }
    }
    protected override void OnResize(EventArgs e) { base.OnResize(e); Geometry(); dirty = 1; }
    protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); Geometry(); dirty = 1; }
    protected override void OnGotFocus(EventArgs e)
    { base.OnGotFocus(e); focused(); lock (Engine.Gate) Engine.Terminal.FocusIn(); dirty = 1; }
    protected override void OnLostFocus(EventArgs e)
    { base.OnLostFocus(e); lock (Engine.Gate) Engine.Terminal.FocusOut(); dirty = 1; }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.Clear(BackColor);
        lock (Engine.Gate)
        {
            var terminal = Engine.Terminal;
            var top = Math.Max(0, terminal.ViewPort.TopRow - scrollOffset);
            var page = terminal.ViewPort.GetPageSpans(top, rows, columns);
            var y = 8f;
            foreach (var row in page)
            {
                var x = 10f;
                foreach (var span in row.Spans)
                {
                    var cells = StringInfo.ParseCombiningCharacters(span.Text).Length;
                    var rectangle = new Rectangle((int)x, (int)y, (int)Math.Ceiling(cells * cellWidth), (int)Math.Ceiling(cellHeight));
                    using var background = new SolidBrush(Resolve(span.BackgroundColor, true));
                    e.Graphics.FillRectangle(background, rectangle);
                    if (!span.Hidden)
                    {
                        using var font = span.Bold || span.Underline ? new Font(Font, (span.Bold ? FontStyle.Bold : FontStyle.Regular) | (span.Underline ? FontStyle.Underline : FontStyle.Regular)) : null;
                        TextRenderer.DrawText(e.Graphics, span.Text, font ?? Font, rectangle, Resolve(span.ForgroundColor, false), TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
                    }
                    x += cells * cellWidth;
                }
                y += cellHeight;
            }
            if (selectionStart is { } start && selectionEnd is { } end)
            {
                if (Compare(start, end) > 0) (start, end) = (end, start);
                using var brush = new SolidBrush(Color.FromArgb(100, 80, 130, 205));
                for (var row = Math.Max(top, start.Y); row <= Math.Min(top + rows - 1, end.Y); row++)
                {
                    var from = row == start.Y ? start.X : 0; var to = row == end.Y ? end.X : columns;
                    e.Graphics.FillRectangle(brush, 10 + from * cellWidth, 8 + (row - top) * cellHeight, Math.Max(0, to - from) * cellWidth, cellHeight);
                }
            }
            if (terminal.CursorState.ShowCursor && scrollOffset == 0 && (!Focused || !terminal.CursorState.BlinkingCursor || Environment.TickCount64 / 500 % 2 == 0))
            {
                var cursor = terminal.ViewPort.CursorPosition;
                var rectangle = new RectangleF(10 + cursor.Column * cellWidth, 8 + cursor.Row * cellHeight, cellWidth, cellHeight);
                using var pen = new Pen(Resolve("#CDCDCD", false));
                if (Focused && terminal.CursorState.CursorShape == ECursorShape.Bar) e.Graphics.DrawLine(pen, rectangle.Left, rectangle.Top, rectangle.Left, rectangle.Bottom);
                else e.Graphics.DrawRectangle(pen, rectangle.X, rectangle.Y, rectangle.Width - 1, rectangle.Height - 1);
            }
            if (scrollOffset > 0) TextRenderer.DrawText(e.Graphics, "Scrollback · type to return", Font, new Point(10, ClientSize.Height - (int)cellHeight - 4), Ui.Foreground, Ui.Header);
        }
        base.OnPaint(e);
    }
    private Color Resolve(string value, bool background)
    {
        var color = ColorTranslator.FromHtml(value);
        if (color.ToArgb() == Color.Black.ToArgb()) return background ? BackColor : Color.FromArgb(96, 112, 135);
        if (color.R == 205 && color.G == 205 && color.B == 205) return theme == "amber" ? Color.FromArgb(255, 210, 125) : theme == "highContrast" ? Color.White : Ui.Foreground;
        return color;
    }
    protected override bool IsInputKey(Keys keyData) => true;
    protected override bool ProcessCmdKey(ref Message message, Keys keyData)
    {
        if (keyData == (Keys.Control | Keys.Shift | Keys.C)) { Copy(); return true; }
        if (keyData == (Keys.Control | Keys.Shift | Keys.V)) { Paste(); return true; }
        return base.ProcessCmdKey(ref message, keyData);
    }
    protected override void OnKeyDown(KeyEventArgs e)
    {
        lock (Engine.Gate)
        {
            scrollOffset = 0;
            if (e.Control && !e.Alt && e.KeyCode >= Keys.A && e.KeyCode <= Keys.Z)
            { Session?.Send([(byte)(e.KeyCode - Keys.A + 1)]); e.Handled = e.SuppressKeyPress = true; }
            else if (e.Control && !e.Alt && e.KeyCode == Keys.Space)
            { Session?.Send([0]); e.Handled = e.SuppressKeyPress = true; }
            else
            {
                var key = e.KeyCode.ToString();
                var sequence = e.KeyCode switch
                {
                    Keys.Return => new byte[] { 13 }, Keys.Back => new byte[] { 127 }, Keys.Escape => new byte[] { 27 },
                    _ => Engine.Terminal.GetKeySequence(key, e.Control, e.Shift)
                };
                if (sequence is not null)
                { if (e.Alt && !e.Control) Session?.Send([27]); Session?.Send(sequence); e.Handled = e.SuppressKeyPress = true; }
            }
        }
        dirty = 1; base.OnKeyDown(e);
    }
    protected override void OnKeyPress(KeyPressEventArgs e)
    {
        if (!e.Handled)
        {
            if (char.IsHighSurrogate(e.KeyChar)) { highSurrogate = e.KeyChar; e.Handled = true; return; }
            var text = char.IsLowSurrogate(e.KeyChar) && highSurrogate is { } high ? new string([high, e.KeyChar]) : e.KeyChar.ToString();
            highSurrogate = null;
            if ((ModifierKeys & (Keys.Alt | Keys.Control)) == Keys.Alt) Session?.Send([27]);
            Session?.Send(Encoding.UTF8.GetBytes(text)); e.Handled = true;
        }
        base.OnKeyPress(e);
    }
    public void Paste()
    {
        try { if (Clipboard.ContainsText()) { Engine.Paste(Clipboard.GetText()); scrollOffset = 0; selectionStart = selectionEnd = null; dirty = 1; } }
        catch (System.Runtime.InteropServices.ExternalException e) { StatusChanged?.Invoke(e.Message, false); }
    }
    public void Copy()
    {
        if (selectionStart is not { } start || selectionEnd is not { } end) return;
        if (Compare(start, end) > 0) (start, end) = (end, start);
        if (start == end) return;
        var lines = new List<string>();
        lock (Engine.Gate)
        {
            for (var row = start.Y; row <= end.Y; row++)
            {
                var line = Engine.Terminal.ViewPort.GetLine(row);
                if (line is null) { lines.Add(""); continue; }
                var from = row == start.Y ? start.X : 0; var to = row == end.Y ? end.X : line.Count;
                lines.Add(string.Concat(line.Skip(from).Take(Math.Max(0, to - from)).Select(c => c.Char + (c.CombiningCharacters ?? ""))).TrimEnd());
            }
        }
        try { var text = string.Join(Environment.NewLine, lines); if (text.Length > 0) Clipboard.SetText(text); }
        catch (System.Runtime.InteropServices.ExternalException e) { StatusChanged?.Invoke(e.Message, false); }
    }
    private static int Compare(Point a, Point b) => a.Y == b.Y ? a.X.CompareTo(b.X) : a.Y.CompareTo(b.Y);
    private Point Cell(Point point) => new(Math.Clamp((int)((point.X - 10) / cellWidth), 0, columns), Math.Clamp((int)((point.Y - 8) / cellHeight), 0, rows - 1));
    private Point BufferCell(Point point) { var cell = Cell(point); cell.Y += Math.Max(0, Engine.Terminal.ViewPort.TopRow - scrollOffset); return cell; }
    protected override void OnMouseDown(MouseEventArgs e)
    {
        Focus();
        lock (Engine.Gate)
        {
            if (Engine.Terminal.MouseTrackingEnabled && (ModifierKeys & Keys.Shift) == 0)
            { var c = Cell(e.Location); Engine.Terminal.MousePress(c.X, c.Y, e.Button == MouseButtons.Left ? 0 : e.Button == MouseButtons.Right ? 1 : 2, (ModifierKeys & Keys.Control) != 0, false); }
            else if (e.Button == MouseButtons.Left) { selectionStart = selectionEnd = BufferCell(e.Location); Capture = true; }
        }
        dirty = 1; base.OnMouseDown(e);
    }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        lock (Engine.Gate)
        {
            if (Capture && selectionStart is not null) selectionEnd = BufferCell(e.Location);
            else if (Engine.Terminal.MouseTrackingEnabled && (ModifierKeys & Keys.Shift) == 0)
            { var c = Cell(e.Location); Engine.Terminal.MouseMove(c.X, c.Y, e.Button == MouseButtons.Left ? 0 : e.Button == MouseButtons.Right ? 1 : e.Button == MouseButtons.Middle ? 2 : 3, (ModifierKeys & Keys.Control) != 0, false); }
        }
        dirty = 1; base.OnMouseMove(e);
    }
    protected override void OnMouseUp(MouseEventArgs e)
    {
        lock (Engine.Gate)
        {
            if (Capture && selectionStart is not null) selectionEnd = BufferCell(e.Location);
            else if (Engine.Terminal.MouseTrackingEnabled && (ModifierKeys & Keys.Shift) == 0)
            { var c = Cell(e.Location); Engine.Terminal.MouseRelease(c.X, c.Y, (ModifierKeys & Keys.Control) != 0, false); }
        }
        Capture = false; dirty = 1; base.OnMouseUp(e);
    }
    protected override void OnMouseWheel(MouseEventArgs e)
    {
        lock (Engine.Gate)
        {
            if (Engine.Terminal.MouseTrackingEnabled && (ModifierKeys & Keys.Shift) == 0)
            {
                var c = Cell(e.Location); var code = e.Delta > 0 ? 64 : 65;
                if (Engine.Terminal.SgrMouseMode) Session?.Send(Encoding.UTF8.GetBytes($"\x1b[<{code};{c.X + 1};{c.Y + 1}M"));
            }
            else scrollOffset = Math.Clamp(scrollOffset + (e.Delta > 0 ? 3 : -3), 0, Engine.Terminal.ViewPort.TopRow);
        }
        dirty = 1; base.OnMouseWheel(e);
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) { repaint.Dispose(); Session?.Dispose(); Font.Dispose(); ContextMenuStrip?.Dispose(); }
        base.Dispose(disposing);
    }
}
