using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Dispatching;

namespace Reqly.Core;

/// <summary>
/// A session of the Swift core, through ReqlyCore.dll: the live one, or a saved one. Calls are
/// asynchronous, and events arrive on the UI thread. ReqlyCore.h describes the C functions.
/// </summary>
public sealed partial class CoreSession : IDisposable
{
    private const string Library = "ReqlyCore.dll";

    private IntPtr handle;
    private GCHandle self;
    private readonly DispatcherQueue ui;

    /// <summary>An event from the core, such as "rows", on the UI thread.</summary>
    public event Action<JsonElement>? EventReceived;

    /// <summary>
    /// Events that came before the window listened, such as a saved session's first rows, which
    /// the core sends while it opens. <see cref="StartEvents"/> hands them over, in order.
    /// </summary>
    private readonly List<JsonElement> heldEvents = [];
    private bool isHoldingEvents = true;

    /// <summary>Hands over the events held since the session opened, then each as it comes. Call it once everything listens.</summary>
    public void StartEvents()
    {
        if (!isHoldingEvents)
        {
            return;
        }
        isHoldingEvents = false;
        foreach (var held in heldEvents)
        {
            EventReceived?.Invoke(held);
        }
        heldEvents.Clear();
    }

    private void Deliver(JsonElement update)
    {
        if (isHoldingEvents)
        {
            heldEvents.Add(update);
            return;
        }
        EventReceived?.Invoke(update);
    }

    private CoreSession(DispatcherQueue ui)
    {
        this.ui = ui;
    }

    /// <summary>Opens a session. Opening a big saved session takes a moment, so it runs off the UI thread.</summary>
    public static async Task<CoreSession> OpenAsync(JsonObject options, DispatcherQueue ui)
    {
        var session = new CoreSession(ui);
        session.self = GCHandle.Alloc(session);
        var context = GCHandle.ToIntPtr(session.self);
        var text = options.ToJsonString();
        string? failure = null;
        session.openFailure = message => failure = message;
        var handle = await Task.Run(() => OpenNative(text, context));
        if (handle == IntPtr.Zero)
        {
            session.self.Free();
            throw new CoreProblem("failed", failure ?? "Reqly couldn't open the session.");
        }
        session.handle = handle;
        session.openFailure = null;
        return session;
    }

    /// <summary>Sends a request and waits for its result. A problem comes back as a <see cref="CoreProblem"/>.</summary>
    public Task<JsonElement> CallAsync(JsonObject request)
    {
        var reply = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        var context = GCHandle.ToIntPtr(GCHandle.Alloc(reply));
        CallNative(handle, request.ToJsonString(), context);
        return reply.Task;
    }

    private static unsafe IntPtr OpenNative(string options, IntPtr context) => Open(options, &OnEvent, context);

    private static unsafe void CallNative(IntPtr session, string request, IntPtr context) =>
        Call(session, request, &OnReply, context);

    /// <summary>Part of a body as bytes: the request's, or the response's, as they came or unpacked.</summary>
    public Task<byte[]?> BodyAsync(ulong exchange, bool request, long offset, long limit, bool unpacked = false)
    {
        var session = handle;
        var part = (request ? 0 : 1) + (unpacked ? 2 : 0);
        return Task.Run(() =>
        {
            var bytes = Body(session, exchange, part, offset, limit, out var length);
            if (bytes == IntPtr.Zero)
            {
                return null;
            }
            try
            {
                var data = new byte[length];
                Marshal.Copy(bytes, data, 0, (int)length);
                return data;
            }
            finally
            {
                Free(bytes);
            }
        });
    }

    /// <summary>Puts your proxy settings back if a Reqly that quit unexpectedly left them pointing at itself.</summary>
    public static bool RestoreProxy(string restoreFile) => RestoreProxySettings(restoreFile) == 1;

    /// <summary>Stops capturing, which puts your proxy settings back, and closes the session.</summary>
    public void Dispose()
    {
        if (handle == IntPtr.Zero)
        {
            return;
        }
        Close(handle);
        handle = IntPtr.Zero;
        self.Free();
    }

    private Action<string>? openFailure;

    // The core calls these on its own threads. An error that escaped one would stop Reqly with no
    // word from .NET, so it's noted first.

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static unsafe void OnEvent(byte* json, IntPtr context)
    {
        var text = Marshal.PtrToStringUTF8((IntPtr)json) ?? "{}";
        CrashReports.Reported.Run(() => Receive(text, context));
    }

    private static void Receive(string text, IntPtr context)
    {
        if (GCHandle.FromIntPtr(context).Target is not CoreSession session)
        {
            return;
        }
        using var document = JsonDocument.Parse(text);
        var root = document.RootElement.Clone();
        if (root.TryGetProperty("event", out var name) && name.GetString() == "openFailed")
        {
            session.openFailure?.Invoke(root.GetProperty("problem").GetProperty("message").GetString() ?? "");
            return;
        }
        session.ui.TryEnqueue(CrashReports.Reported.Queued(() => session.Deliver(root)));
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static unsafe void OnReply(byte* json, IntPtr context)
    {
        var text = Marshal.PtrToStringUTF8((IntPtr)json) ?? "{}";
        CrashReports.Reported.Run(() => Answer(text, context));
    }

    private static void Answer(string text, IntPtr context)
    {
        var handle = GCHandle.FromIntPtr(context);
        var reply = (TaskCompletionSource<JsonElement>)handle.Target!;
        handle.Free();
        using var document = JsonDocument.Parse(text);
        var root = document.RootElement;
        if (root.TryGetProperty("problem", out var problem))
        {
            reply.SetException(new CoreProblem(
                problem.GetProperty("code").GetString() ?? "failed", problem.GetProperty("message").GetString() ?? ""));
        }
        else
        {
            reply.SetResult(root.GetProperty("result").Clone());
        }
    }

    [LibraryImport(Library, EntryPoint = "reqly_open", StringMarshalling = StringMarshalling.Utf8)]
    private static unsafe partial IntPtr Open(string options, delegate* unmanaged[Cdecl]<byte*, IntPtr, void> events, IntPtr context);

    [LibraryImport(Library, EntryPoint = "reqly_call", StringMarshalling = StringMarshalling.Utf8)]
    private static unsafe partial void Call(IntPtr session, string request, delegate* unmanaged[Cdecl]<byte*, IntPtr, void> done, IntPtr context);

    [LibraryImport(Library, EntryPoint = "reqly_body")]
    private static partial IntPtr Body(IntPtr session, ulong exchange, int part, long offset, long limit, out long length);

    [LibraryImport(Library, EntryPoint = "reqly_free")]
    private static partial void Free(IntPtr pointer);

    [LibraryImport(Library, EntryPoint = "reqly_restore_proxy", StringMarshalling = StringMarshalling.Utf8)]
    private static partial int RestoreProxySettings(string restoreFile);

    [LibraryImport(Library, EntryPoint = "reqly_close")]
    private static partial void Close(IntPtr session);

    /// <summary>How removing Reqly's certificate went, as <c>reqly_remove_root</c> says.</summary>
    public enum RootRemoval
    {
        Failed = -1,
        Nothing = 0,
        Removed = 1,
        Declined = 2,
    }

    /// <summary>
    /// Removes Reqly's certificate as Reqly is uninstalled: from your trusted roots, which Windows
    /// asks you to confirm, and its key with it. A test run's stand-in file only goes.
    /// </summary>
    public static RootRemoval RemoveRoot(string rootFile, bool standIn) => (RootRemoval)RemoveRootCertificate(rootFile, standIn ? 1 : 0);

    [LibraryImport(Library, EntryPoint = "reqly_remove_root", StringMarshalling = StringMarshalling.Utf8)]
    private static partial int RemoveRootCertificate(string rootFile, int standIn);

    /// <summary>
    /// From now on, a crash in Swift's code writes the crashed thread's stack to the standard
    /// error, which this run's crash log has, for the crash report. Then, if the stack went
    /// through .NET's code, it calls <paramref name="then"/> on the crashed thread, to name those
    /// frames, which only .NET can.
    /// </summary>
    [LibraryImport(Library, EntryPoint = "reqly_catch_crashes")]
    public static unsafe partial void CatchCrashes(delegate* unmanaged[Cdecl]<void> then);

    /// <summary>For the self-check: stops Reqly as a failed check in the core does, on one of the core's threads, with Swift's "Fatal error".</summary>
    [LibraryImport(Library, EntryPoint = "reqly_crash_for_test", StringMarshalling = StringMarshalling.Utf8)]
    public static partial void CrashForTest(string message);

    /// <summary>For the self-check: as <see cref="CrashForTest"/>, on this thread, one of .NET's.</summary>
    [LibraryImport(Library, EntryPoint = "reqly_crash_here_for_test", StringMarshalling = StringMarshalling.Utf8)]
    public static partial void CrashHereForTest(string message);
}

/// <summary>Why a call to the core failed: a code to act on, and a message to show.</summary>
public sealed class CoreProblem(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}
