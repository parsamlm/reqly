using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Reqly.Core;
using Reqly.Settings;
using Reqly.Traffic;
using Windows.Graphics;
using Windows.System;

namespace Reqly.Tray;

/// <summary>
/// The panel that opens from Reqly's icon in the notification area, as the Mac's menu-bar panel
/// does: capturing at a glance, the switches you reach for most, and the way to Reqly's windows. It
/// opens above the icon, as Windows' own panels from the taskbar do, and closes when you click
/// anywhere else.
/// </summary>
public sealed partial class NotificationPanel : Window
{
    /// <summary>The panel's width at 100% scaling.</summary>
    private const double PanelWidth = 320;
    /// <summary>The room between the panel and the taskbar or the screen's edges, at 100%.</summary>
    private const double Gap = 12;

    private readonly MainWindow main;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer timer;
    /// <summary>When the panel last closed, in ms since Windows started: a click on the icon right after doesn't open it again.</summary>
    private long dismissed = -10_000;
    /// <summary>While the panel shows what's so, so its switches changing aren't you changing them.</summary>
    private bool isShowing;
    private bool isSummarizing;
    private bool isOpening;
    /// <summary>Whether the panel was closed while it opened, as by double-clicking the icon.</summary>
    private bool isCancelled;

    public NotificationPanel(MainWindow main)
    {
        this.main = main;
        InitializeComponent();
        AppIcon.Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Reqly.png")))
        {
            DecodePixelWidth = 32,
            DecodePixelType = DecodePixelType.Logical,
        };
        // As the taskbar's own panels are: no title bar, not in the taskbar or Alt+Tab, and above other windows.
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            presenter.IsAlwaysOnTop = true;
            presenter.SetBorderAndTitleBar(true, false);
        }
        AppWindow.IsShownInSwitchers = false;
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var round = RoundCorners;
        DwmSetWindowAttribute(handle, CornerPreference, ref round, sizeof(int));
        SystemBackdrop = new DesktopAcrylicBackdrop();
        Activated += (_, args) =>
        {
            // Clicking anywhere else closes it, as it closes a menu.
            if (args.WindowActivationState == WindowActivationState.Deactivated && AppWindow.IsVisible)
            {
                Dismiss();
            }
        };
        // The requests come in while it shows.
        timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(500);
        timer.Tick += CrashReports.Reported.Tick(() => _ = ShowTrafficAsync());
        main.CaptureChanged += OnCaptureChanged;
        App.Current.Updates.Changed += OnCaptureChanged;
        Closed += (_, _) =>
        {
            timer.Stop();
            main.CaptureChanged -= OnCaptureChanged;
            App.Current.Updates.Changed -= OnCaptureChanged;
        };
    }

    /// <summary>Whether the panel shows now.</summary>
    public bool IsOpen => AppWindow.IsVisible;

    /// <summary>The panel's contents, for the self-check's picture of it.</summary>
    public UIElement View => Root;

    /// <summary>Opens the panel by a point on the screen, the icon's, or closes it if it's open, as clicking the icon does.</summary>
    public void Toggle(PointInt32 near)
    {
        if (IsOpen)
        {
            Dismiss();
            return;
        }
        // A click on the icon while the panel is open takes the panel's focus first, which closes
        // it, so that click doesn't open it again; nor does a double-click's second.
        if (Environment.TickCount64 - dismissed < 400)
        {
            return;
        }
        _ = OpenAsync(near);
    }

    /// <summary>Opens the panel by a point on the screen, once it knows what to show.</summary>
    public async Task OpenAsync(PointInt32 near)
    {
        if (isOpening)
        {
            return;
        }
        isOpening = true;
        isCancelled = false;
        try
        {
            Show();
            ShowTraffic(await main.SummarizeTrafficAsync());
            await WindowLayout.LoadedAsync(Root);
            if (isCancelled)
            {
                return;
            }
            Place(near);
            AppWindow.Show();
            Activate();
            SetForegroundWindow(WinRT.Interop.WindowNative.GetWindowHandle(this));
            // Escape and the arrow keys work from the start, with no focus ring until you use them.
            CaptureSwitch.Focus(FocusState.Programmatic);
            timer.Start();
        }
        finally
        {
            isOpening = false;
        }
    }

    /// <summary>Closes the panel. A click on the icon right after doesn't open it again.</summary>
    public void Dismiss()
    {
        isCancelled = true;
        dismissed = Environment.TickCount64;
        timer.Stop();
        AppWindow.Hide();
    }

    /// <summary>
    /// Puts the panel by the taskbar, as Windows' own panels from it sit: above the icon on a taskbar
    /// at the bottom, clear of the screen's edges.
    /// </summary>
    private void Place(PointInt32 near)
    {
        var area = DisplayArea.GetFromPoint(near, DisplayAreaFallback.Primary);
        var work = area.WorkArea;
        var outer = area.OuterBounds;
        // Onto the icon's screen first, so the panel is laid out at that screen's scaling.
        AppWindow.Move(new PointInt32(work.X, work.Y));
        var scale = Screens.ScaleAt(near);
        Root.Measure(new Windows.Foundation.Size(PanelWidth, double.PositiveInfinity));
        // What shows is the window's inside. Its frame is invisible but for its line, and with no
        // title bar, ResizeClient would leave room for one, so the frame is measured on the window.
        var size = new SizeInt32((int)Math.Ceiling(PanelWidth * scale), (int)Math.Ceiling(Root.DesiredSize.Height * scale));
        var frame = new SizeInt32(AppWindow.Size.Width - AppWindow.ClientSize.Width, AppWindow.Size.Height - AppWindow.ClientSize.Height);
        AppWindow.Resize(new SizeInt32(size.Width + frame.Width, size.Height + frame.Height));
        var inset = Inset();
        var gap = (int)Math.Round(Gap * scale);
        var left = work.X + gap;
        var right = Math.Max(left, work.X + work.Width - size.Width - gap);
        var top = work.Y + gap;
        var bottom = Math.Max(top, work.Y + work.Height - size.Height - gap);
        var x = Math.Clamp(near.X - size.Width / 2, left, right);
        var y = Math.Clamp(near.Y - size.Height - gap, top, bottom);
        // By the taskbar, on whichever edge of the screen it is. A taskbar that hides itself leaves
        // the panel by the point.
        if (work.Y + work.Height < outer.Y + outer.Height)
        {
            y = bottom;
        }
        else if (work.Y > outer.Y)
        {
            y = top;
        }
        else if (work.X > outer.X)
        {
            x = left;
        }
        else if (work.X + work.Width < outer.X + outer.Width)
        {
            x = right;
        }
        AppWindow.Move(new PointInt32(x - inset.X, y - inset.Y));
    }

    /// <summary>Where the window's inside starts, from the window's corner, in pixels.</summary>
    private PointInt32 Inset()
    {
        var origin = new NativePoint();
        ClientToScreen(WinRT.Interop.WindowNative.GetWindowHandle(this), ref origin);
        return new PointInt32(origin.X - AppWindow.Position.X, origin.Y - AppWindow.Position.Y);
    }

    private void OnCaptureChanged()
    {
        if (IsOpen)
        {
            Show();
        }
    }

    /// <summary>What's so: capturing, the switches and HTTPS, as the live window has them.</summary>
    private void Show()
    {
        isShowing = true;
        var state = main.CaptureState;
        var problem = main.CaptureProblem;
        var hasFailed = problem is not null && state == MainWindow.Capture.Stopped;
        StatusText.Text = state switch
        {
            MainWindow.Capture.Starting => "Starting…",
            MainWindow.Capture.Capturing => $"Capturing on port {main.CapturingPort}",
            MainWindow.Capture.Stopping => "Stopping…",
            _ => hasFailed ? "Couldn't start capturing" : "Not capturing",
        };
        StatusDot.Fill = state == MainWindow.Capture.Capturing
            ? Palette.Status("success")
            : hasFailed ? Palette.Failure : (Brush)Application.Current.Resources["TextFillColorTertiaryBrush"];
        CaptureSwitch.IsOn = state is MainWindow.Capture.Capturing or MainWindow.Capture.Starting;
        CaptureSwitch.IsEnabled = main.CanCapture && state is MainWindow.Capture.Stopped or MainWindow.Capture.Capturing;
        ToolTipService.SetToolTip(CaptureSwitch, CaptureSwitch.IsOn ? "Stop capturing" : "Start capturing");
        ProblemText.Text = problem ?? "";
        ProblemText.Foreground = Palette.Failure;
        ProblemText.Visibility = problem is null ? Visibility.Collapsed : Visibility.Visible;
        BreakpointsSwitch.IsOn = main.Rules?.IsOn("breakpoint") == true;
        SlowNetworkSwitch.IsOn = main.Rules?.IsOn("slowNetwork") == true;
        BreakpointsSwitch.IsEnabled = main.Rules is not null;
        SlowNetworkSwitch.IsEnabled = main.Rules is not null;
        DecryptedHostsText.Text = DecryptedHosts();
        // The value is read with the title, once.
        AutomationProperties.SetName(DecryptHttpsItem, $"Decrypt HTTPS…, {DecryptedHostsText.Text}");
        var ready = App.Current.Updates.ReadyVersion;
        UpdateItem.Visibility = ready is null ? Visibility.Collapsed : Visibility.Visible;
        UpdateItem.Content = $"Restart to update to Reqly {ready}…";
        isShowing = false;
    }

    private string DecryptedHosts()
    {
        if (main.Https is not { IsTrusted: true } https)
        {
            return "Not set up";
        }
        if (https.Hosts.IncludesEveryHost)
        {
            return "All hosts";
        }
        var count = https.Hosts.Entries.Count(entry => entry.IsOn);
        return count == 1 ? "1 host" : $"{count:N0} hosts";
    }

    /// <summary>How many requests there are and the newest one, of all the traffic, whatever the live window's list shows.</summary>
    private async Task ShowTrafficAsync()
    {
        if (isSummarizing)
        {
            return;
        }
        isSummarizing = true;
        try
        {
            ShowTraffic(await main.SummarizeTrafficAsync());
        }
        finally
        {
            isSummarizing = false;
        }
    }

    private void ShowTraffic(WireTrafficSummary? summary)
    {
        SummaryText.Text = $"{Format.Requests(summary?.Total ?? 0)} · {Format.Size(summary?.Bytes ?? 0)}";
        if (summary?.Newest is not { } newest)
        {
            Newest.Visibility = Visibility.Collapsed;
            NoTrafficText.Visibility = Visibility.Visible;
            NoTrafficText.Text = main.CaptureState == MainWindow.Capture.Capturing ? "Waiting for traffic" : "No requests yet";
            return;
        }
        Newest.Visibility = Visibility.Visible;
        NoTrafficText.Visibility = Visibility.Collapsed;
        var isFailed = newest.State == "failed";
        NewestFailed.Visibility = isFailed ? Visibility.Visible : Visibility.Collapsed;
        NewestDot.Visibility = !isFailed && newest.StatusClass is not null ? Visibility.Visible : Visibility.Collapsed;
        NewestDot.Fill = Palette.Status(newest.StatusClass);
        NewestCode.Text = newest.Status is int status ? $"{status} {newest.Method}" : newest.Method;
        var host = (newest.Scheme, newest.Port) is ("http", 80) or ("https", 443) ? newest.Host : $"{newest.Host}:{newest.Port}";
        NewestAddress.Text = host + (newest.Kind == "http" ? newest.Target : "");
        var said = isFailed ? "failed" : newest.Status?.ToString() ?? (newest.Kind == "tunnel" ? "encrypted connection" : "in progress");
        AutomationProperties.SetName(Newest, $"Newest: {said}, {newest.Method} {host}");
    }

    // MARK: What you choose

    private async void OnCaptureToggled(object sender, RoutedEventArgs e)
    {
        if (isShowing)
        {
            return;
        }
        await main.SetCapturingAsync(CaptureSwitch.IsOn);
        Show();
    }

    private async void OnRuleKindToggled(object sender, RoutedEventArgs e)
    {
        if (isShowing || sender is not ToggleSwitch { Tag: string kind } toggle)
        {
            return;
        }
        await main.SetRuleKindOnAsync(kind, toggle.IsOn);
        Show();
    }

    private void OnDecryptHttpsClicked(object sender, RoutedEventArgs e)
    {
        Dismiss();
        main.ShowSettings(SettingsWindow.Pane.Https);
    }

    private void OnDevicesClicked(object sender, RoutedEventArgs e)
    {
        Dismiss();
        main.ShowDevices();
    }

    private void OnOpenClicked(object sender, RoutedEventArgs e)
    {
        Dismiss();
        main.BringForward();
    }

    private void OnSettingsClicked(object sender, RoutedEventArgs e)
    {
        Dismiss();
        main.ShowSettings(SettingsWindow.Pane.General);
    }

    private void OnUpdateClicked(object sender, RoutedEventArgs e)
    {
        Dismiss();
        main.BringForward();
        _ = main.ShowUpdatesAsync();
    }

    private void OnQuitClicked(object sender, RoutedEventArgs e)
    {
        Dismiss();
        App.Current.Quit();
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Escape)
        {
            e.Handled = true;
            Dismiss();
        }
    }

    // MARK: For the self-check

    /// <summary>What the panel shows, and where, for the self-check.</summary>
    public string Describe()
    {
        var work = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var inset = Inset();
        var place = $"showing {AppWindow.ClientSize.Width}×{AppWindow.ClientSize.Height} at {AppWindow.Position.X + inset.X},{AppWindow.Position.Y + inset.Y} " +
            $"(contents {Root.ActualWidth:0}×{Root.ActualHeight:0}, measured {Root.DesiredSize.Height:0} tall) in a work area {work.X},{work.Y} {work.Width}×{work.Height}";
        var newest = Newest.Visibility == Visibility.Visible ? $"{NewestCode.Text} {NewestAddress.Text}" : NoTrafficText.Text;
        return $"{(IsOpen ? "open" : "closed")} {place} · {StatusText.Text} · capturing switch {(CaptureSwitch.IsOn ? "on" : "off")} · " +
            $"{SummaryText.Text} · newest: {newest} · breakpoints {(BreakpointsSwitch.IsOn ? "on" : "off")} · " +
            $"slow network {(SlowNetworkSwitch.IsOn ? "on" : "off")} · Decrypt HTTPS: {DecryptedHostsText.Text}";
    }

    /// <summary>Flips a switch as clicking it does: capture, breakpoint or slowNetwork.</summary>
    public void Flip(string name)
    {
        var toggle = name switch
        {
            "capture" => CaptureSwitch,
            "breakpoint" => BreakpointsSwitch,
            _ => SlowNetworkSwitch,
        };
        toggle.IsOn = !toggle.IsOn;
    }

    /// <summary>Chooses Open Reqly, as clicking it does.</summary>
    public void ChooseOpen() => OnOpenClicked(this, new RoutedEventArgs());

    // MARK: Windows

    private const int CornerPreference = 33;
    private const int RoundCorners = 2;

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X;
        public int Y;
    }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetForegroundWindow(IntPtr window);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ClientToScreen(IntPtr window, ref NativePoint point);
}
