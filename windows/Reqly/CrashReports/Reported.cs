using Microsoft.UI.Dispatching;
using Windows.Foundation;

namespace Reqly.CrashReports;

/// <summary>
/// What Windows calls in Reqly outside WinUI's own events, noting an error that escapes it, with
/// its stack, before the error stops Reqly as it did. Such an error, in a queued callback, a
/// timer's tick, a window's event or a call from the core, goes from .NET to Windows' code, which
/// ends Reqly without telling .NET or WinUI, so only Windows' own report of the crash would be
/// left. WinUI's events, and what an await goes on with, are noted already, by
/// <see cref="App"/>'s handlers and by <see cref="ReportingContext"/>.
/// </summary>
internal static class Reported
{
    /// <summary>Work for <see cref="DispatcherQueue.TryEnqueue(DispatcherQueueHandler)"/>.</summary>
    public static DispatcherQueueHandler Queued(DispatcherQueueHandler work) => () => Run(work.Invoke);

    /// <summary>A handler for a <see cref="DispatcherQueueTimer"/>'s tick.</summary>
    public static TypedEventHandler<DispatcherQueueTimer, object> Tick(Action work) => (_, _) => Run(work);

    /// <summary>A handler for an event that isn't WinUI's, such as a window's <c>AppWindow.Closing</c>.</summary>
    public static TypedEventHandler<TSender, TArgs> Handler<TSender, TArgs>(TypedEventHandler<TSender, TArgs> handler) =>
        (sender, args) => Run(() => handler(sender, args));

    public static void Run(Action work)
    {
        try
        {
            work();
        }
        catch (Exception error)
        {
            Note(error);
            throw;
        }
    }

    /// <summary>Notes an error that's about to stop Reqly, in its log and for the crash report.</summary>
    public static void Note(Exception error)
    {
        AppLog.Write($"stopped by an error: {error}");
        CrashLog.Stopped(error);
    }
}
