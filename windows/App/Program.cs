using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using MultiTerminal.Core;

namespace MultiTerminal;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        var selfTest = args.Length == 2 && args[0] == "--self-test" && !string.IsNullOrWhiteSpace(args[1]);
        if (args.Length > 0 && !selfTest && !(args.Length == 1 && args[0] is "--version" or "--check-running"))
        { AttachConsole(uint.MaxValue); Console.Error.WriteLine("Usage: MultiTerminal.exe [--version | --check-running | --self-test <report.json>]"); return 2; }
        if (args.Length == 1 && args[0] == "--version") { AttachConsole(uint.MaxValue); Console.WriteLine("MultiTerminal 0.1.0-windows.1 (native Windows)"); return 0; }
        var mutexName = "Local\\MultiTerminal-Source-" + WindowsIdentity.GetCurrent().User?.Value + (selfTest ? "-Test-" + Guid.NewGuid().ToString("N") : "");
        using var instance = new Mutex(true, mutexName, out var first);
        if (args.Length == 1 && args[0] == "--check-running") return first ? 0 : 10;
        if (!first && !selfTest)
        {
            foreach (var candidate in Process.GetProcessesByName("MultiTerminal"))
            {
                if (candidate.Id == Environment.ProcessId || candidate.MainWindowHandle == IntPtr.Zero) continue;
                ShowWindow(candidate.MainWindowHandle, 9); SetForegroundWindow(candidate.MainWindowHandle); break;
            }
            return 0;
        }
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2); Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
        { MessageBox.Show("This build requires Windows 11 x64.", "MultiTerminal"); return 1; }
        Application.ThreadException += (_, e) =>
        {
            if (selfTest) WindowsSmoke.CallbackErrors.Enqueue(e.Exception.ToString());
            else MessageBox.Show(e.Exception.Message, "MultiTerminal", MessageBoxButtons.OK, MessageBoxIcon.Error);
        };
        if (selfTest)
        {
            AppPaths.Root = Path.Combine(Path.GetTempPath(), "multiterminal-test-" + Guid.NewGuid().ToString("N"));
            ConPtySession.TestWithoutProfile = true;
        }
        try
        {
            var store = new WorkspaceStore(AppPaths.Settings);
            if (store.State.Workspaces.Count == 0) store.Create();
            using var window = new MainForm(store);
            if (selfTest) window.Shown += async (_, _) => await WindowsSmoke.Run(window, args[1]);
            Application.Run(window);
            return Environment.ExitCode;
        }
        catch (Exception e)
        {
            if (selfTest) { File.WriteAllText(args[1], System.Text.Json.JsonSerializer.Serialize(new { passed = false, error = e.ToString() })); return 1; }
            MessageBox.Show(e.Message, "MultiTerminal", MessageBoxButtons.OK, MessageBoxIcon.Error); return 1;
        }
    }
    [DllImport("kernel32.dll")] private static extern bool AttachConsole(uint processId);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
}
