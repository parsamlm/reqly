using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Dispatching;
using Microsoft.Win32.SafeHandles;

namespace Reqly;

/// <summary>
/// One Reqly at a time. Opening a file, or Reqly itself, while Reqly runs hands the launch to the
/// Reqly already running, which opens the file or shows its live window. The new one quits before
/// it touches anything: two would listen on one port and share your proxy settings, and each
/// would put back what the other set.
/// <para>
/// A Reqly that keeps its things in other files is another Reqly: test runs, with files of their
/// own, run beside yours.
/// </para>
/// </summary>
internal static partial class SingleInstance
{
    /// <summary>Held for as long as this Reqly runs, so later launches find it.</summary>
    private static Mutex? running;
    private static string? name;

    /// <summary>
    /// Hands this launch's files, or none for the live window, to the Reqly running with these
    /// files, if one is. Returns whether it did, when this launch should quit at once.
    /// </summary>
    public static bool HandOff(AppOptions options)
    {
        name = Name(options);
        var mutex = new Mutex(initiallyOwned: true, $@"Local\{name}", out var isFirst);
        if (isFirst)
        {
            running = mutex;
            return false;
        }
        if (Send(name, [.. options.FilesToOpen.Select(Path.GetFullPath)]))
        {
            mutex.Dispose();
            return true;
        }
        // The Reqly running didn't take it: it's quitting, or stuck. This one runs once it's gone.
        try
        {
            if (!mutex.WaitOne(TimeSpan.FromSeconds(10)))
            {
                mutex.Dispose();
                return true;
            }
        }
        catch (AbandonedMutexException)
        {
            // It quit without letting go, as every Reqly does. The mutex is this one's now.
        }
        running = mutex;
        return false;
    }

    /// <summary>
    /// Takes what later launches hand over, and gives it to <paramref name="open"/> on this
    /// thread: the files to open, or none for the live window.
    /// </summary>
    public static void Listen(Action<string[]> open)
    {
        if (running is null || name is not { } pipeName)
        {
            return;
        }
        var queue = DispatcherQueue.GetForCurrentThread();
        _ = Task.Run(async () =>
        {
            while (true)
            {
                try
                {
                    await using var pipe = new NamedPipeServerStream(
                        pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                    await pipe.WaitForConnectionAsync();
                    using var waiting = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                    var files = JsonSerializer.Deserialize<string[]>(await ReadLineAsync(pipe, waiting.Token)) ?? [];
                    if (queue.TryEnqueue(CrashReports.Reported.Queued(() => open(files))))
                    {
                        await pipe.WriteAsync(Taken, waiting.Token);
                        await pipe.FlushAsync(waiting.Token);
                    }
                }
                catch (Exception error) when (error is IOException or JsonException or OperationCanceledException)
                {
                    AppLog.Write($"couldn't take a later launch's files: {error.Message}");
                }
            }
        });
    }

    /// <summary>Sends the files, and waits for the Reqly running to say it has them.</summary>
    private static bool Send(string pipeName, string[] files)
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            pipe.Connect(10_000);
            // Windows lets the app you just started come forward, and this one passes that on.
            if (GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var process))
            {
                AllowSetForegroundWindow(process);
            }
            using var waiting = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            pipe.Write([.. JsonSerializer.SerializeToUtf8Bytes(files), (byte)'\n']);
            pipe.Flush();
            var answer = new byte[1];
            return pipe.ReadAsync(answer, waiting.Token).AsTask().GetAwaiter().GetResult() == 1 && answer[0] == Taken[0];
        }
        catch (Exception error) when (error is IOException or TimeoutException or UnauthorizedAccessException or OperationCanceledException)
        {
            return false;
        }
    }

    private static readonly byte[] Taken = "k"u8.ToArray();

    /// <summary>A line, without its end, of a size a list of files can be.</summary>
    private static async Task<string> ReadLineAsync(Stream stream, CancellationToken cancellation)
    {
        var line = new List<byte>();
        var buffer = new byte[4096];
        while (line.Count < 1 << 20)
        {
            var count = await stream.ReadAsync(buffer, cancellation);
            if (count == 0)
            {
                break;
            }
            var end = Array.IndexOf(buffer, (byte)'\n', 0, count);
            line.AddRange(buffer.Take(end < 0 ? count : end));
            if (end >= 0)
            {
                break;
            }
        }
        return Encoding.UTF8.GetString([.. line]);
    }

    /// <summary>The same for every launch that keeps its things in these files.</summary>
    private static string Name(AppOptions options)
    {
        string[] files =
        [
            options.SessionsFolder, options.ProxyRestoreFile, options.SettingsFile, options.RulesFile, options.DevicesFile,
            options.ProtobufFile, options.ConnectionsFile, options.SecretsFile, options.RootFile,
        ];
        var text = string.Join("\n", files.Select(file => Path.GetFullPath(file).ToUpperInvariant()));
        return "Reqly-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)), 0, 8);
    }

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint processId);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AllowSetForegroundWindow(uint processId);
}
