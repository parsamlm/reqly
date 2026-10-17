using System.Diagnostics;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Reqly.CrashReports;

/// <summary>
/// What a run of Reqly says as it stops, in a file of its own. Swift's runtime writes its error,
/// and its backtracer where the crash happened, to the standard error, which a Windows app has
/// nowhere, so Reqly points it at the file; an error that .NET or WinUI stops Reqly with goes there
/// too. A clean quit deletes the file, so the one a crashed run leaves is there at the next launch.
/// </summary>
internal static partial class CrashLog
{
    /// <summary>How the runs' files are named: this, when the run started, and its process.</summary>
    public const string Prefix = "Reqly-";

    /// <summary>The line before an error that .NET or WinUI stopped Reqly with.</summary>
    public const string StoppedInDotNet = "*** Reqly stopped on an error in .NET ***";

    /// <summary>The line before .NET's frames of a thread that crashed in Swift's code it called.</summary>
    public const string DotNetFrames = "*** .NET's frames of the crashed thread ***";

    /// <summary>The line after a frame that native code called: the frames after it are further down, past native code.</summary>
    public const string CalledFromNative = "--- called from native code ---";

    private static SafeFileHandle? file;
    private static readonly Lock Writing = new();
    /// <summary>The error noted last, which WinUI may hand on again as it stops Reqly.</summary>
    private static Exception? noted;

    /// <summary>This run's file, once it has one.</summary>
    public static string? FilePath { get; private set; }

    /// <summary>Starts this run's file in the folder, and points the standard error at it.</summary>
    public static void Start(string folder)
    {
        try
        {
            Directory.CreateDirectory(folder);
            var started = DateTime.UtcNow;
            var path = Path.Combine(folder, $"{Prefix}{started.ToLocalTime():yyyyMMdd-HHmmss}-{Environment.ProcessId}.txt");
            // Every writer only appends, and the backtracer that Swift's runtime starts as a crash
            // happens inherits the file, to write to the standard error it's given.
            var security = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), InheritHandle = 1 };
            var handle = CreateFileW(path, AppendData | Synchronize, ShareRead | ShareWrite | ShareDelete, ref security, CreateAlways, NormalFile, IntPtr.Zero);
            if (handle.IsInvalid)
            {
                AppLog.Write($"couldn't start this run's crash log: error {Marshal.GetLastPInvokeError()}");
                return;
            }
            file = handle;
            FilePath = path;
            Write($"Reqly {Help.AppInfo.Version}\r\n{Environment.ProcessPath}\r\nStarted {started:O}\r\n\r\n");
            SetStdHandle(StandardError, handle.DangerousGetHandle());
            // The C runtime's own standard error, which Swift's runtime writes with, on a copy of
            // the handle, which the C runtime closes as its own.
            var process = GetCurrentProcess();
            if (DuplicateHandle(process, handle.DangerousGetHandle(), process, out var copy, 0, true, SameAccess))
            {
                var descriptor = _open_osfhandle(copy, WriteOnly | Append | Binary);
                if (descriptor >= 0)
                {
                    _dup2(descriptor, 2);
                    _close(descriptor);
                }
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            AppLog.Write($"couldn't start this run's crash log: {error.Message}");
        }
    }

    /// <summary>Notes the error that stops Reqly, which .NET or WinUI hands it before it does.</summary>
    public static void Stopped(Exception error, string? message = null)
    {
        if (ReferenceEquals(Interlocked.Exchange(ref noted, error), error))
        {
            return;
        }
        var text = new StringBuilder();
        text.Append(StoppedInDotNet).Append("\r\n");
        // WinUI's message can say more than its exception's.
        if (!string.IsNullOrWhiteSpace(message) && message != error.Message)
        {
            text.Append("WinUI: ").Append(message.Trim()).Append("\r\n");
        }
        text.Append(error).Append("\r\n\r\n");
        Write(text.ToString());
    }

    /// <summary>
    /// .NET's frames of a thread that crashed in Swift's code it called, which the core asks for
    /// once it has written the stack, on the crashed thread: .NET compiles its code as it runs,
    /// so only it can name those frames, and only before Reqly ends. Each frame that native code
    /// called is followed by <see cref="CalledFromNative"/>, as the core's stack has native code
    /// between those frames and the next.
    /// </summary>
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static void WriteDotNetFrames()
    {
        try
        {
            var text = new StringBuilder(DotNetFrames).Append("\r\n");
            // Past this one: the frames below the call into the core, innermost first.
            foreach (var frame in new StackTrace(1, true).GetFrames())
            {
                if (frame.GetMethod() is not { } method)
                {
                    continue;
                }
                text.Append(new StackTrace(frame).ToString().TrimEnd());
                text.Append("\r\n");
                if (method.IsDefined(typeof(UnmanagedCallersOnlyAttribute), false))
                {
                    text.Append(CalledFromNative).Append("\r\n");
                }
            }
            Write(text.Append("\r\n").ToString());
        }
        catch (Exception)
        {
            // Reqly is ending; the core's stack is written already.
        }
    }

    /// <summary>
    /// Compiles <see cref="WriteDotNetFrames"/> and reads Reqly's debug information for .NET's
    /// frames now, in the background, so a crash has less to do.
    /// </summary>
    public static void PrepareDotNetFrames()
    {
        var method = typeof(CrashLog).GetMethod(nameof(WriteDotNetFrames), BindingFlags.Public | BindingFlags.Static);
        _ = Task.Run(() =>
        {
            try
            {
                if (method is not null)
                {
                    RuntimeHelpers.PrepareMethod(method.MethodHandle);
                }
                _ = new StackTrace(true).ToString();
            }
            catch (Exception error) when (error is InvalidOperationException or NotSupportedException or IOException)
            {
                AppLog.Write($"couldn't prepare .NET's frames for a crash: {error.Message}");
            }
        });
    }

    /// <summary>Reqly quit as it should, so its file goes and the next launch has nothing to report.</summary>
    public static void Finish()
    {
        if (FilePath is not { } path)
        {
            return;
        }
        try
        {
            File.Delete(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            AppLog.Write($"couldn't delete this run's crash log: {error.Message}");
        }
    }

    private static void Write(string text)
    {
        if (file is null)
        {
            return;
        }
        var bytes = Encoding.UTF8.GetBytes(text);
        lock (Writing)
        {
            WriteFile(file, bytes, bytes.Length, out _, IntPtr.Zero);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes
    {
        public int Length;
        public IntPtr Descriptor;
        public int InheritHandle;
    }

    private const uint AppendData = 0x0004;
    private const uint Synchronize = 0x0010_0000;
    private const uint ShareRead = 0x1;
    private const uint ShareWrite = 0x2;
    private const uint ShareDelete = 0x4;
    private const uint CreateAlways = 2;
    private const uint NormalFile = 0x80;
    private const int StandardError = -12;
    private const uint SameAccess = 0x2;
    private const int WriteOnly = 0x0001;
    private const int Append = 0x0008;
    private const int Binary = 0x8000;

    [LibraryImport("kernel32.dll", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    private static partial SafeFileHandle CreateFileW(string name, uint access, uint share, ref SecurityAttributes security, uint disposition, uint attributes, IntPtr template);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool WriteFile(SafeFileHandle file, byte[] buffer, int count, out int written, IntPtr overlapped);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetStdHandle(int which, IntPtr handle);

    [LibraryImport("kernel32.dll")]
    private static partial IntPtr GetCurrentProcess();

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DuplicateHandle(IntPtr sourceProcess, IntPtr source, IntPtr targetProcess, out IntPtr target, uint access,
        [MarshalAs(UnmanagedType.Bool)] bool inherit, uint options);

    [LibraryImport("ucrtbase.dll")]
    private static partial int _open_osfhandle(IntPtr handle, int flags);

    [LibraryImport("ucrtbase.dll")]
    private static partial int _dup2(int from, int to);

    [LibraryImport("ucrtbase.dll")]
    private static partial int _close(int descriptor);
}
