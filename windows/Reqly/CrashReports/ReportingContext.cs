namespace Reqly.CrashReports;

/// <summary>
/// The window thread's synchronization context, WinUI's own, which notes an error that escapes
/// what it runs before the error stops Reqly. Such an error, as from an async method that nothing
/// waits for, goes from .NET to WinUI's code, which ends Reqly without telling it.
/// </summary>
internal sealed class ReportingContext(SynchronizationContext inner) : SynchronizationContext
{
    public override void Post(SendOrPostCallback callback, object? state) => inner.Post(_ => Run(callback, state), null);

    public override void Send(SendOrPostCallback callback, object? state) => inner.Send(_ => Run(callback, state), null);

    public override SynchronizationContext CreateCopy() => new ReportingContext(inner.CreateCopy());

    private static void Run(SendOrPostCallback callback, object? state)
    {
        try
        {
            callback(state);
        }
        catch (Exception error)
        {
            AppLog.Write($"stopped by an error: {error}");
            CrashLog.Stopped(error);
            throw;
        }
    }
}
