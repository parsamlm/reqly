using System.Runtime;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Reqly.Core;
using Reqly.Settings;
using Reqly.Tray;
using Windows.Graphics;

namespace Reqly;

public partial class App : Application
{
    private readonly AppOptions options;
    /// <summary>
    /// The window for the traffic being captured. Reqly opened to show files keeps it hidden until
    /// you open Reqly. Closed, it hides while Reqly goes on in the notification area, or while
    /// files' windows are open. Reqly quits when it closes for good.
    /// </summary>
    private MainWindow? window;
    /// <summary>The windows for saved sessions and HAR files you opened.</summary>
    private readonly List<MainWindow> fileWindows = [];
    private bool isQuitting;
    /// <summary>Reqly's icon in the notification area, while Settings show it.</summary>
    private NotifyIcon? notifyIcon;
    /// <summary>The panel the icon opens, once it has.</summary>
    private NotificationPanel? panel;
    /// <summary>About Reqly, while it's open.</summary>
    private Help.AboutWindow? about;
    /// <summary>Microsoft's terms, the first time Reqly opens, until you agree to them.</summary>
    private Help.TermsWindow? terms;
    /// <summary>The offer to report Reqly's last crash, while it's open.</summary>
    private CrashReports.CrashReportWindow? crashReport;
    /// <summary>For the self-check, the crash on its way: a timer only a local held could be collected first, and never fire.</summary>
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? crashTimer;
    /// <summary>Files that later launches handed over before Reqly opened, which open once it does.</summary>
    private readonly List<string> waitingFiles = [];

    public App(AppOptions options)
    {
        this.options = options;
        AppLog.Open(options.LogFile);
        // What stopped Reqly, in its log and in the run's crash log, which the next launch offers to
        // report: Windows' own report of a crash says only where. WinUI's message can say more
        // than its exception's.
        UnhandledException += (_, e) =>
        {
            AppLog.Write($"stopped by an error: {e.Message}{Environment.NewLine}{e.Exception}");
            CrashReports.CrashLog.Stopped(e.Exception, e.Message);
        };
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            AppLog.Write($"stopped by an error: {e.ExceptionObject}");
            if (e.ExceptionObject is Exception error)
            {
                CrashReports.CrashLog.Stopped(error);
            }
        };
        // .NET's full garbage collections, which stop everything, run in the background instead
        // while Reqly runs, so a burst of traffic doesn't freeze the window.
        GCSettings.LatencyMode = GCLatencyMode.SustainedLowLatency;
        // Reqly follows Windows' light or dark mode, unless a test run asks for one.
        if (options.Theme is "light" or "dark")
        {
            RequestedTheme = options.Theme == "light" ? ApplicationTheme.Light : ApplicationTheme.Dark;
        }
        InitializeComponent();
    }

    public static new App Current => (App)Application.Current;

    /// <summary>Light or dark, when a test run asks for one; otherwise Reqly follows Windows' mode.</summary>
    public string? Theme => options.Theme;

    /// <summary>The window for the traffic being captured, which sends the requests you write and resend.</summary>
    public MainWindow? Main => window;

    /// <summary>The windows for the files you opened.</summary>
    public IReadOnlyList<MainWindow> FileWindows => fileWindows;

    /// <summary>Your settings, which every window shares, so one window's change isn't lost to another's.</summary>
    public AppSettings Settings { get; private set; } = new();

    /// <summary>Reqly's updates, which an installed Reqly checks for and installs as it quits.</summary>
    public Updates.UpdatesModel Updates { get; private set; } = null!;

    /// <summary>Whether Reqly's icon is in the notification area, where Reqly goes on when its window closes.</summary>
    public bool ShowsNotificationIcon => notifyIcon?.IsAdded == true && !isQuitting;

    /// <summary>
    /// Whether closing the live window hides it, as Reqly goes on: in the notification area, or for
    /// the files' windows still open. Otherwise closing it quits Reqly.
    /// </summary>
    public bool HidesLiveWindowOnClose => !isQuitting && (ShowsNotificationIcon || fileWindows.Count > 0);

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Settings = AppSettings.Load(options.SettingsFile);
        // Settings a Reqly that crashed left pointing at itself go back first.
        if (options.SetsSystemProxy && options.ProxySettingsStandIn is null && CoreSession.RestoreProxy(options.ProxyRestoreFile))
        {
            AppLog.Write("put back the proxy settings a Reqly that quit unexpectedly left");
        }
        Updates = new Updates.UpdatesModel(Settings, isAllowed: options.SmokeReport is null && options.ChecksForUpdates != false, options.UpdatesFrom);
        SingleInstance.Listen(OnLaterLaunch);
        // The first time, and whenever Microsoft's terms change, Reqly opens once you agree to them.
        if (!options.HasAgreedToTerms && Settings.AgreedTerms != Help.Terms.Version)
        {
            terms = new Help.TermsWindow();
            terms.Agreed += () =>
            {
                Settings.AgreedTerms = Help.Terms.Version;
                Settings.Save();
                AppLog.Write("agreed to Microsoft's terms");
                terms = null;
                Open();
            };
            terms.Declined += () =>
            {
                AppLog.Write("quit without agreeing to Microsoft's terms");
                terms = null;
                Exit();
            };
            _ = terms.OpenAsync();
            if (options.SmokeReport is { } report)
            {
                _ = CheckTermsAsync(terms, report);
            }
            return;
        }
        Open();
    }

    /// <summary>Opens Reqly: the live window, or with files to open, only theirs.</summary>
    private void Open()
    {
        window = new MainWindow(options);
        window.Closed += (_, _) =>
        {
            // Reqly quits. The files' windows go with it, each letting go of its copy of the
            // traffic, and so do the icon and its panel. A downloaded update installs now.
            isQuitting = true;
            panel?.Close();
            panel = null;
            notifyIcon?.Dispose();
            notifyIcon = null;
            about?.Close();
            crashReport?.Close();
            foreach (var opened in fileWindows.ToList())
            {
                opened.Close();
            }
            Updates.InstallOnQuit(restarts: false);
        };
        window.CaptureChanged += ShowNotificationIconTip;
        Updates.Start(window.DispatcherQueue);
        if (Settings.ShowsNotificationIcon)
        {
            AddNotificationIcon();
        }
        var files = options.FilesToOpen.Concat(waitingFiles).ToList();
        waitingFiles.Clear();
        if (files.Count == 0)
        {
            window.BringForward();
            OfferCrashReport();
            if (options.SmokeCrash is { } kind)
            {
                CrashForTest(kind);
            }
            return;
        }
        // Opened to show files, as from File Explorer, Reqly shows only theirs.
        window.OpenHidden();
        foreach (var path in files)
        {
            OpenFile(path);
        }
        if (options.SmokeReport is { } report)
        {
            _ = window.CheckOpeningFilesAsync(report);
        }
    }

    /// <summary>The offer to report Reqly's last crash, while it's open, for the self-check.</summary>
    public CrashReports.CrashReportWindow? CrashReport => crashReport;

    /// <summary>
    /// Offers to report Reqly's last crash when the live window opens, as the Mac does: each crash
    /// once, and the first time Reqly opens, none of Windows' reports from before.
    /// </summary>
    private void OfferCrashReport()
    {
        if (window is null || Environment.ProcessPath is not { } program)
        {
            return;
        }
        var since = Settings.CrashReportsCheckedAt;
        Settings.CrashReportsCheckedAt = DateTime.UtcNow;
        Settings.Save();
        var folder = options.CrashReportsFolder;
        var queue = window.DispatcherQueue;
        _ = Task.Run(() =>
        {
            CrashReports.CrashReporter.Report? found;
            try
            {
                found = CrashReports.CrashReporter.Find(folder, since, program);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                AppLog.Write($"couldn't look for crash reports: {error.Message}");
                return;
            }
            if (found is null)
            {
                return;
            }
            AppLog.Write($"offering to report a crash: {found.Title}");
            queue.TryEnqueue(CrashReports.Reported.Queued(() =>
            {
                if (isQuitting || crashReport is not null)
                {
                    return;
                }
                crashReport = new CrashReports.CrashReportWindow(found, opensBrowser: options.SmokeReport is null);
                crashReport.Closed += (_, _) => crashReport = null;
                _ = crashReport.OpenAsync(window);
            }));
        });
    }

    /// <summary>
    /// For the self-check: crashes Reqly once its window shows, as a failed check in Swift does, on
    /// one of the core's threads (swift) or in a call from .NET (swift-here), or as an error in .NET
    /// does: in an async method that nothing waits for (dotnet), a timer's tick (timer), or work
    /// queued for the window's thread (queue).
    /// </summary>
    private void CrashForTest(string kind)
    {
        var queue = window!.DispatcherQueue;
        var timer = crashTimer = queue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(2);
        timer.IsRepeating = false;
        timer.Tick += CrashReports.Reported.Tick(() =>
        {
            AppLog.Write($"crashing for the self-check, in {kind}");
            switch (kind)
            {
                case "swift":
                    // A moment later, on one of the core's own threads.
                    Core.CoreSession.CrashForTest("Reqly test: a crash in the core");
                    break;
                case "swift-here":
                    Core.CoreSession.CrashHereForTest("Reqly test: a crash in the core, called from .NET");
                    break;
                case "timer":
                    throw new InvalidOperationException("Reqly test: a crash in a timer's tick");
                case "queue":
                    queue.TryEnqueue(CrashReports.Reported.Queued(() => throw new InvalidOperationException("Reqly test: a crash in queued work")));
                    break;
                default:
                    CrashLater();
                    break;
            }
        });
        timer.Start();
    }

    /// <summary>An error in an async method that nothing waits for, the commonest kind in an app like Reqly.</summary>
    private static async void CrashLater()
    {
        await Task.Yield();
        throw new InvalidOperationException("Reqly test: a crash in .NET");
    }

    /// <summary>For the self-check: a picture of Microsoft's terms as they first show, then agreeing, as the Agree button does.</summary>
    private static async Task CheckTermsAsync(Help.TermsWindow shown, string report)
    {
        await Task.Delay(1500);
        AppLog.Write($"terms: {shown.Describe()}");
        AppLog.Write(await Smoke.Pictures.SaveAsync(shown.View, report + ".terms.png"));
        shown.Agree();
    }

    /// <summary>Reqly started again while it runs: with files, it opens them; without, it shows the live window.</summary>
    private void OnLaterLaunch(string[] files)
    {
        AppLog.Write(files.Length == 0 ? "opened again: showing the live window" : $"opened again with {files.Length} file(s)");
        // Before you agree to Microsoft's terms, they come forward, and the files open after.
        if (terms is not null)
        {
            waitingFiles.AddRange(files);
            terms.Activate();
            return;
        }
        if (files.Length == 0)
        {
            window?.BringForward();
        }
        foreach (var path in files)
        {
            OpenFile(path);
        }
    }

    /// <summary>Opens a saved session or a HAR file in a window of its own, or brings its window forward.</summary>
    public MainWindow OpenFile(string path)
    {
        var full = Path.GetFullPath(path);
        if (fileWindows.FirstOrDefault(opened => string.Equals(opened.FilePath, full, StringComparison.OrdinalIgnoreCase)) is { } open)
        {
            open.BringForward();
            return open;
        }
        var fileWindow = new MainWindow(options, full);
        fileWindows.Add(fileWindow);
        fileWindow.Closed += (_, _) =>
        {
            fileWindows.Remove(fileWindow);
            // The last one closing, while the live window is hidden, quits Reqly, unless Reqly goes
            // on in the notification area: you opened Reqly itself, or it captures.
            if (fileWindows.Count == 0 && !isQuitting && window is { IsShowing: false } hidden
                && !(ShowsNotificationIcon && (hidden.HasShown || hidden.CaptureState != MainWindow.Capture.Stopped)))
            {
                Quit();
            }
        };
        fileWindow.Activate();
        return fileWindow;
    }

    /// <summary>About Reqly, while it's open, for the self-check.</summary>
    public Help.AboutWindow? About => about;

    /// <summary>Opens About Reqly over the window it was chosen in, or brings it forward, as Help › About Reqly does.</summary>
    public void ShowAbout(Window? over)
    {
        if (about is not null)
        {
            about.Activate();
            return;
        }
        about = new Help.AboutWindow();
        about.Closed += (_, _) => about = null;
        _ = about.OpenAsync(over);
    }

    /// <summary>Quits Reqly to install the downloaded update, and opens it again after.</summary>
    public void RestartToUpdate()
    {
        Updates.InstallOnQuit(restarts: true);
        Quit();
    }

    /// <summary>
    /// Quits Reqly, as Quit Reqly does: every window closes, and capturing stops, which puts your
    /// proxy settings back.
    /// </summary>
    public void Quit()
    {
        if (isQuitting || window is null)
        {
            return;
        }
        AppLog.Write("quitting");
        isQuitting = true;
        window.Close();
    }

    // MARK: The notification area

    private void AddNotificationIcon()
    {
        if (notifyIcon is null)
        {
            notifyIcon = new NotifyIcon();
            notifyIcon.Invoked += point => ToggleNotificationPanel(point);
            notifyIcon.DoubleClicked += () =>
            {
                panel?.Dismiss();
                window?.BringForward();
            };
        }
        ShowNotificationIconTip();
        notifyIcon.Add();
    }

    /// <summary>Puts the icon in the notification area or takes it away, as you chose in Settings.</summary>
    public void SetShowsNotificationIcon(bool shows)
    {
        if (Settings.ShowsNotificationIcon == shows)
        {
            return;
        }
        Settings.ShowsNotificationIcon = shows;
        Settings.Save();
        if (shows)
        {
            AddNotificationIcon();
            return;
        }
        panel?.Close();
        panel = null;
        notifyIcon?.Dispose();
        notifyIcon = null;
        // Reqly doesn't go on unseen: closed into the notification area, its window shows again.
        if (window is { IsShowing: false } live && !isQuitting && (live.HasShown || live.CaptureState != MainWindow.Capture.Stopped || fileWindows.Count == 0))
        {
            live.BringForward();
        }
    }

    /// <summary>What the icon says under the pointer: whether Reqly captures, and on which port.</summary>
    private void ShowNotificationIconTip()
    {
        if (notifyIcon is null || window is null)
        {
            return;
        }
        notifyIcon.Tip = window.CaptureState switch
        {
            MainWindow.Capture.Capturing => $"Reqly\nCapturing on port {window.CapturingPort}",
            MainWindow.Capture.Starting => "Reqly\nStarting…",
            MainWindow.Capture.Stopping => "Reqly\nStopping…",
            _ => "Reqly\nNot capturing",
        };
    }

    /// <summary>Opens the icon's panel by a point on the screen, or closes it, as clicking the icon does.</summary>
    public void ToggleNotificationPanel(PointInt32? near = null)
    {
        if (window is null || isQuitting)
        {
            return;
        }
        panel ??= new NotificationPanel(window);
        panel.Toggle(near ?? NotificationIconPoint());
    }

    /// <summary>The icon's panel, once it has opened, for the self-check.</summary>
    public NotificationPanel? NotificationPanel => panel;

    /// <summary>Where the icon is on the screen, in pixels, while it shows.</summary>
    public RectInt32? NotificationIconBounds => notifyIcon?.Bounds;

    /// <summary>Clicks the icon as Windows says a click happened, for the self-check.</summary>
    public void ClickNotificationIcon() => notifyIcon?.PostClick();

    /// <summary>What the icon is and where, for the self-check.</summary>
    public string DescribeNotificationIcon() => notifyIcon is { } icon
        ? $"{(icon.IsAdded ? "in the notification area" : "not added")}, {icon.Describe()}, at {(icon.Bounds is { } bounds ? $"{bounds.X},{bounds.Y} {bounds.Width}×{bounds.Height}" : "no place")}, saying \"{icon.Tip.ReplaceLineEndings(" · ")}\""
        : "none";

    /// <summary>The middle of the icon, or without one, the corner of the screen it would be in.</summary>
    private PointInt32 NotificationIconPoint()
    {
        if (notifyIcon?.Bounds is { } bounds)
        {
            return new PointInt32(bounds.X + bounds.Width / 2, bounds.Y + bounds.Height / 2);
        }
        var work = DisplayArea.Primary.WorkArea;
        return new PointInt32(work.X + work.Width, work.Y + work.Height);
    }

    /// <summary>
    /// The first time the live window closes into the notification area, a notification says that
    /// Reqly goes on there, and how to open it again or quit it.
    /// </summary>
    public void SayReqlyGoesOn()
    {
        if (Settings.HasSaidItGoesOn || notifyIcon is not { IsAdded: true } icon || window is null)
        {
            return;
        }
        Settings.HasSaidItGoesOn = true;
        Settings.Save();
        const string title = "Reqly is still running";
        // Windows keeps a new app's icon under Show hidden icons until you choose to show it.
        const string where = "To open Reqly again or quit it, click its icon at the end of the taskbar, or under Show hidden icons.";
        var text = window.CaptureState == MainWindow.Capture.Capturing ? $"It goes on capturing. {where}" : where;
        // Test runs leave Windows' notifications alone unless they check this one.
        if (options.SmokeReport is not null && options.SmokeParts?.Contains("notice") != true)
        {
            AppLog.Write($"would say: {title}: {text}");
            return;
        }
        icon.Notify(title, text);
    }
}
