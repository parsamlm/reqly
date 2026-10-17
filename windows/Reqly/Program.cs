using System.Diagnostics;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Reqly.Core;
using Velopack;

namespace Reqly;

public static class Program
{
    /// <summary>
    /// Starts Reqly, or with <c>--restore-proxy-after &lt;process&gt; &lt;file&gt;</c>, the watcher: it
    /// waits for that Reqly to quit, then puts your proxy settings back if Reqly left them pointing
    /// at itself, as after a crash. The watcher shows no windows.
    /// </summary>
    [STAThread]
    public static int Main(string[] arguments)
    {
        // Velopack's part, first, as it asks. Setup and the updater start Reqly with arguments of
        // their own as they install, update or uninstall it, and those runs end here.
        VelopackApp.Build()
            // An update installs when Reqly quits, or when you restart Reqly for it. Applied as
            // Reqly starts, it would stop the Reqly running whenever a second one started, such
            // as one that File Explorer started to open a file.
            .SetAutoApplyOnStartup(false)
            .OnAfterInstallFastCallback(_ => Install.Installation.Installed())
            .OnAfterUpdateFastCallback(_ => Install.Installation.Installed())
            .OnBeforeUninstallFastCallback(_ => Install.Installation.Uninstalling())
            .Run();
        if (arguments is ["--restore-proxy-after", var process, var restoreFile])
        {
            return Watch(int.Parse(process), restoreFile);
        }
        var options = AppOptions.Parse(arguments);
        // With Reqly already running, it takes this launch's files, and this one goes.
        if (SingleInstance.HandOff(options))
        {
            return 0;
        }
        // What this run says if it crashes, which the next launch offers to report, with the
        // crashed thread's stack when Swift's code stops it.
        CrashReports.CrashLog.Start(options.CrashReportsFolder);
        try
        {
            unsafe
            {
                CoreSession.CatchCrashes(&CrashReports.CrashLog.WriteDotNetFrames);
            }
            CrashReports.CrashLog.PrepareDotNetFrames();
        }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException)
        {
            AppLog.Write($"couldn't watch for crashes in the core: {error.Message}");
        }
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(parameters =>
        {
            // WinUI's, noting an error that escapes it for the crash report, as from an async
            // method that nothing waits for.
            SynchronizationContext.SetSynchronizationContext(
                new CrashReports.ReportingContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread())));
            new App(options);
        });
        // Reqly quit as it should, so there's nothing to report.
        CrashReports.CrashLog.Finish();
        return 0;
    }

    private static int Watch(int processID, string restoreFile)
    {
        try
        {
            using var reqly = Process.GetProcessById(processID);
            reqly.WaitForExit();
        }
        catch (ArgumentException)
        {
            // It's gone already.
        }
        return CoreSession.RestoreProxy(restoreFile) ? 1 : 0;
    }

    /// <summary>Starts a watcher for this Reqly, which outlives it if it crashes.</summary>
    public static void StartWatcher(string restoreFile)
    {
        // Through the shell, so the watcher gets none of Reqly's handles. A watcher that had
        // Reqly's listening socket would keep its port open after Reqly stops capturing, and
        // capturing couldn't start on that port again.
        var watcher = new ProcessStartInfo(Environment.ProcessPath!)
        {
            UseShellExecute = true,
            Arguments = $"--restore-proxy-after {Environment.ProcessId} \"{restoreFile}\"",
        };
        Process.Start(watcher);
    }
}
