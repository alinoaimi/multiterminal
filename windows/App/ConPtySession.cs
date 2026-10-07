using System.Collections;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Channels;
using Microsoft.Win32.SafeHandles;
using MultiTerminal.Core;

namespace MultiTerminal;

/// <summary>A real Windows pseudoconsole with job-scoped child-process lifetime.</summary>
internal sealed class ConPtySession : IDisposable
{
    private readonly object lifetime = new();
    private readonly Channel<byte[]> inputQueue = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(64) { SingleReader = true, SingleWriter = false });
    private SafeFileHandle? job;
    private SafeFileHandle? process;
    private FileStream? input;
    private FileStream? output;
    private IntPtr console;
    private volatile bool disposed;
    private volatile bool exited;
    private Task? processWait;
    public static bool TestWithoutProfile { get; set; }
    public int ProcessId { get; private set; }
    public bool Exited => exited;
    public event Action<byte[]>? Output;
    public event Action<int>? ChildExited;
    public event Action<string>? Failed;

    public void Start(string shell, string directory, int columns, int rows)
    {
        if (ProcessId != 0 || disposed) throw new InvalidOperationException("This terminal session has already started.");
        var (executable, arguments) = ShellCommand(shell);
        SafeFileHandle? readInput = null, writeInput = null, readOutput = null, writeOutput = null;
        IntPtr attributes = IntPtr.Zero, environment = IntPtr.Zero;
        PROCESS_INFORMATION info = default;
        try
        {
            Check(CreatePipe(out readInput, out writeInput, IntPtr.Zero, 0));
            Check(CreatePipe(out readOutput, out writeOutput, IntPtr.Zero, 0));
            Marshal.ThrowExceptionForHR(CreatePseudoConsole(new COORD((short)columns, (short)rows), readInput, writeOutput, 0, out console));
            input = new FileStream(writeInput, FileAccess.Write); writeInput = null;
            output = new FileStream(readOutput, FileAccess.Read); readOutput = null;
            var inputStream = input;
            _ = Task.Run(async () =>
            {
                try
                {
                    await foreach (var bytes in inputQueue.Reader.ReadAllAsync())
                    { if (disposed) break; inputStream.Write(bytes); inputStream.Flush(); }
                }
                catch (Exception e) when (e is IOException or ObjectDisposedException)
                { if (!disposed && !Exited) Failed?.Invoke(e.Message); }
            });
            // Drain output before any teardown. ClosePseudoConsole may wait for
            // its output to be consumed and must never block the UI thread.
            var outputStream = output;
            _ = Task.Run(() => ReadOutput(outputStream));
            nuint size = 0;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            attributes = Marshal.AllocHGlobal(checked((int)size));
            Check(InitializeProcThreadAttributeList(attributes, 1, 0, ref size));
            Check(UpdateProcThreadAttribute(attributes, 0, (IntPtr)0x00020016, console, (nuint)IntPtr.Size, IntPtr.Zero, IntPtr.Zero));
            var startup = new STARTUPINFOEX { StartupInfo = new STARTUPINFO { cb = Marshal.SizeOf<STARTUPINFOEX>() }, AttributeList = attributes };
            var variables = Environment.GetEnvironmentVariables().Cast<DictionaryEntry>().ToDictionary(e => (string)e.Key, e => (string?)e.Value ?? "", StringComparer.OrdinalIgnoreCase);
            variables["TERM"] = "xterm-256color"; variables["COLORTERM"] = "truecolor";
            variables["TERM_PROGRAM"] = "MultiTerminal"; variables["TERM_PROGRAM_VERSION"] = "0.1.0-windows.1";
            environment = Marshal.StringToHGlobalUni(string.Join('\0', variables.OrderBy(p => p.Key, StringComparer.OrdinalIgnoreCase).Select(p => $"{p.Key}={p.Value}")) + "\0\0");
            var command = new StringBuilder(WindowsCommandLine.Quote(executable) + arguments);
            Check(CreateProcessW(executable, command, IntPtr.Zero, IntPtr.Zero, false, 0x00080000 | 0x00000400 | 0x00000004, environment, directory, ref startup, out info));
            process = new SafeFileHandle(info.Process, true); info.Process = IntPtr.Zero;
            job = CreateJobObjectW(IntPtr.Zero, null);
            if (job.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            var limits = new JOB_EXTENDED_LIMIT_INFORMATION { Basic = new JOB_BASIC_LIMIT_INFORMATION { LimitFlags = 0x00002000 } };
            Check(SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<JOB_EXTENDED_LIMIT_INFORMATION>()));
            Check(AssignProcessToJobObject(job, process));
            if (ResumeThread(info.Thread) == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
            ProcessId = (int)info.ProcessId;
            var processHandle = process;
            processWait = Task.Run(() =>
            {
                WaitForSingleObject(processHandle, uint.MaxValue);
                GetExitCodeProcess(processHandle, out var code);
                exited = true;
                if (!disposed) ChildExited?.Invoke((int)code);
            });
        }
        catch
        {
            if (process is { IsInvalid: false }) TerminateProcess(process, 1);
            Dispose();
            throw;
        }
        finally
        {
            if (info.Thread != IntPtr.Zero) CloseHandle(info.Thread);
            if (attributes != IntPtr.Zero) { DeleteProcThreadAttributeList(attributes); Marshal.FreeHGlobal(attributes); }
            if (environment != IntPtr.Zero) Marshal.FreeHGlobal(environment);
            readInput?.Dispose(); writeOutput?.Dispose(); writeInput?.Dispose(); readOutput?.Dispose();
        }
    }
    private void ReadOutput(FileStream stream)
    {
        try
        {
            var buffer = new byte[16384];
            int count;
            while ((count = stream.Read(buffer)) > 0)
                if (!disposed) Output?.Invoke(buffer.AsSpan(0, count).ToArray());
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException or InvalidOperationException)
        { if (!disposed) Failed?.Invoke(e.Message); }
    }
    public void Send(byte[] bytes)
    {
        if (disposed || Exited || input is null) return;
        if (!inputQueue.Writer.TryWrite(bytes)) Failed?.Invoke("Terminal input is busy. Wait for the command to consume its input and try again.");
    }
    public void Resize(int columns, int rows)
    {
        lock (lifetime)
        {
            if (!disposed && console != IntPtr.Zero && !Exited)
                Marshal.ThrowExceptionForHR(ResizePseudoConsole(console, new COORD((short)columns, (short)rows)));
        }
    }
    public bool HasChildProcesses()
    {
        if (disposed || Exited || job is null) return false;
        if (!QueryInformationJobObject(job, 1, out var info, (uint)Marshal.SizeOf<JOB_BASIC_ACCOUNTING_INFORMATION>(), IntPtr.Zero)) return true;
        return info.ActiveProcesses > 1;
    }
    public void Dispose()
    {
        IntPtr handle;
        lock (lifetime)
        {
            if (disposed) return;
            disposed = true;
            handle = console; console = IntPtr.Zero;
            // All descendants in the job stop when its last handle closes.
            job?.Dispose(); job = null;
            inputQueue.Writer.TryComplete();
        }
        _ = Task.Run(() =>
        {
            if (handle != IntPtr.Zero) ClosePseudoConsole(handle);
            input?.Dispose(); output?.Dispose(); processWait?.GetAwaiter().GetResult(); process?.Dispose();
        });
    }
    public static (string Executable, string Arguments) ShellCommand(string shell)
    {
        var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
        var executable = shell switch
        {
            "powershell" => Path.Combine(system, "WindowsPowerShell", "v1.0", "powershell.exe"),
            "pwsh" => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe"),
            "cmd" => Path.Combine(system, "cmd.exe"),
            "wsl" => Path.Combine(system, "wsl.exe"),
            _ => throw new InvalidDataException("Unknown shell profile.")
        };
        if (!File.Exists(executable)) throw new FileNotFoundException($"{shell} is not installed. Choose a different shell from the pane menu.", executable);
        return (executable, shell is "powershell" or "pwsh" ? " -NoLogo" + (TestWithoutProfile ? " -NoProfile" : "") : shell == "cmd" ? " /D" : "");
    }
    private static void Check(bool result) { if (!result) throw new Win32Exception(Marshal.GetLastWin32Error()); }

    [StructLayout(LayoutKind.Sequential)] private readonly struct COORD(short x, short y) { public readonly short X = x; public readonly short Y = y; }
    [StructLayout(LayoutKind.Sequential)] private struct STARTUPINFO
    {
        public int cb; public IntPtr Reserved, Desktop, Title;
        public uint X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
        public ushort ShowWindow, Reserved2Length; public IntPtr Reserved2, StdInput, StdOutput, StdError;
    }
    [StructLayout(LayoutKind.Sequential)] private struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr AttributeList; }
    [StructLayout(LayoutKind.Sequential)] private struct PROCESS_INFORMATION { public IntPtr Process, Thread; public uint ProcessId, ThreadId; }
    [StructLayout(LayoutKind.Sequential)] private struct JOB_BASIC_LIMIT_INFORMATION
    { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public nuint MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit; public nuint Affinity; public uint PriorityClass, SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)] private struct IO_COUNTERS { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
    [StructLayout(LayoutKind.Sequential)] private struct JOB_EXTENDED_LIMIT_INFORMATION
    { public JOB_BASIC_LIMIT_INFORMATION Basic; public IO_COUNTERS Io; public nuint ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
    [StructLayout(LayoutKind.Sequential)] private struct JOB_BASIC_ACCOUNTING_INFORMATION
    { public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime; public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses; }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, IntPtr attributes, uint size);
    [DllImport("kernel32.dll")] private static extern int CreatePseudoConsole(COORD size, SafeFileHandle input, SafeFileHandle output, uint flags, out IntPtr console);
    [DllImport("kernel32.dll")] private static extern int ResizePseudoConsole(IntPtr console, COORD size);
    [DllImport("kernel32.dll")] private static extern void ClosePseudoConsole(IntPtr console);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, uint flags, ref nuint size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, nuint size, IntPtr previousValue, IntPtr returnSize);
    [DllImport("kernel32.dll")] private static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CreateProcessW(string application, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory, ref STARTUPINFOEX startup, out PROCESS_INFORMATION info);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateProcess(SafeFileHandle process, uint code);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateJobObjectW(IntPtr attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(SafeFileHandle job, int infoClass, ref JOB_EXTENDED_LIMIT_INFORMATION info, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(SafeFileHandle job, SafeFileHandle process);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool QueryInformationJobObject(SafeFileHandle job, int infoClass, out JOB_BASIC_ACCOUNTING_INFORMATION info, uint size, IntPtr returnSize);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(SafeFileHandle handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetExitCodeProcess(SafeFileHandle process, out uint code);
}
