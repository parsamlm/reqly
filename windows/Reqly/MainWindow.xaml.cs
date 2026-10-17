using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Reqly.Core;
using Reqly.Https;
using Reqly.Settings;
using Reqly.Smoke;
using Reqly.Traffic;
using Windows.Graphics;
using Windows.System;

namespace Reqly;

/// <summary>
/// The main window, laid out as the Mac's: the sidebar, the request list with its filters, and the
/// selected request's details, with capturing and clearing above them and what Reqly is doing below.
/// </summary>
public sealed partial class MainWindow : Window
{
    /// <summary>Whether Reqly captures, or is starting or stopping.</summary>
    public enum Capture
    {
        Stopped,
        Starting,
        Capturing,
        Stopping,
    }

    private readonly AppOptions options;
    private readonly AppSettings settings;
    /// <summary>The saved session or HAR file this window shows, or none for the traffic being captured.</summary>
    private readonly string? file;

    public string? FilePath => file;
    private CoreSession? session;
    private RequestList? list;
    private Sidebar? sidebar;
    private HttpsModel? https;
    private SettingsWindow? settingsWindow;
    /// <summary>Setup, while it shows. Only one dialog can show at a time.</summary>
    private HttpsSetupDialog? setup;
    private Capture capture = Capture.Stopped;
    private int? capturingPort;
    private bool hasWatcher;
    /// <summary>Why capturing last failed to start or stop, shown until it works again.</summary>
    private string? problem;
    /// <summary>Why traffic can't be saved right now, if it can't.</summary>
    private string? storageProblem;
    /// <summary>The self-check's own HTTPS server, while it runs.</summary>
    private TestTlsServer? testServer;
    private ScrollViewer? listScroller;
    private readonly StringBuilder report = new();
    /// <summary>The traffic being captured opening, which can start before the window shows.</summary>
    private Task? opening;
    /// <summary>Whether the window has shown, so it has a place and panes worth keeping.</summary>
    private bool hasShown;
    /// <summary>What Reqly does as it opens, which the live window starts the first time it shows.</summary>
    private Task? starting;
    /// <summary>Whether the live window was maximized when it last closed, as it is again once it shows.</summary>
    private bool showsMaximized;
    /// <summary>Whether the live window was closed while files were open, which hides it.</summary>
    private bool isHidden;

    public MainWindow(AppOptions options, string? file = null)
    {
        this.options = options;
        this.file = file;
        settings = App.Current.Settings;
        InitializeComponent();
        if (file is not null)
        {
            // A file's window, laid out like the main one, without the controls for capturing.
            var name = Path.GetFileName(file);
            Title = $"{name} - Reqly";
            AppTitleBar.Subtitle = name;
            CaptureButton.Visibility = Visibility.Collapsed;
            CaptureMenu.Visibility = Visibility.Collapsed;
            // Rules act on the traffic being captured, so they're the main window's.
            RulesMenu.Visibility = Visibility.Collapsed;
            BreakpointsButton.Visibility = Visibility.Collapsed;
            SlowNetworkButton.Visibility = Visibility.Collapsed;
        }
        AppWindow.Resize(new SizeInt32(1360, 860));
        if (file is null)
        {
            RestorePlace();
        }
        var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "Reqly.ico");
        AppWindow.SetIcon(icon);
        // Windows 11's own material, with the title bar drawn by the app.
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppTitleBar.IconSource = new ImageIconSource { ImageSource = new BitmapImage(new Uri(icon)) };
        AddShortcuts();
        AddRuleMenu(AddRuleItem);
        Root.ActualThemeChanged += (_, _) => UseTheme();
        // WinUI loads a window's content even before the window shows, so loading doesn't mean it shows.
        Root.Loaded += async (_, _) =>
        {
            UseTheme();
            if (file is not null)
            {
                await OpenFileAsync(file);
                return;
            }
            await (opening ??= OpenAsync());
        };
        AppWindow.Closing += CrashReports.Reported.Handler<Microsoft.UI.Windowing.AppWindow, Microsoft.UI.Windowing.AppWindowClosingEventArgs>((_, args) =>
        {
            // The live window hides instead while Reqly goes on: in the notification area, or for
            // the files still open.
            if (file is null && App.Current.HidesLiveWindowOnClose)
            {
                args.Cancel = true;
                HideLiveWindow();
            }
        });
        Closed += (_, _) =>
        {
            if (file is null && hasShown && !isHidden)
            {
                SavePlace();
            }
            CloseOwnWindows();
            // Closing stops capturing, which puts your proxy settings back. A file's copy of its
            // traffic goes; the file stays as it was.
            session?.Dispose();
            testServer?.Dispose();
        };
    }

    /// <summary>
    /// Whether the window shows, minimized or not. The live window hides while Reqly shows only
    /// files, and once closed while Reqly goes on in the notification area.
    /// </summary>
    public bool IsShowing => AppWindow.IsVisible;

    /// <summary>Whether the window has shown in this run: Reqly was opened, not only a file in it.</summary>
    public bool HasShown => hasShown;

    /// <summary>
    /// Opens the traffic being captured while the window stays hidden, as when Reqly opens to show
    /// files: their windows send requests and read bodies through it. What Reqly does as it opens,
    /// such as starting to capture, waits until the window shows.
    /// </summary>
    public void OpenHidden() => opening ??= OpenAsync();

    /// <summary>
    /// Shows the window, hidden or minimized, and brings it forward. The live window, the first
    /// time it shows, does what Reqly does as it opens.
    /// </summary>
    public void BringForward()
    {
        if (isHidden)
        {
            isHidden = false;
            AppWindow.Show();
        }
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
        {
            if (!hasShown && showsMaximized)
            {
                presenter.Maximize();
            }
            else if (presenter.State == Microsoft.UI.Windowing.OverlappedPresenterState.Minimized)
            {
                presenter.Restore();
            }
        }
        Activate();
        hasShown = true;
        if (file is null)
        {
            starting ??= StartAsync();
        }
    }

    /// <summary>
    /// Closes the window, as its close button does. The live window hides instead while Reqly goes
    /// on, and opening Reqly again shows it: with its icon in the notification area, Reqly goes on as
    /// it was, capturing too, as on the Mac. Without the icon, it goes on only while files are open:
    /// capturing stops and its other windows close, but its session stays for the files' windows,
    /// which send requests and read bodies through it.
    /// </summary>
    private void CloseOrHide()
    {
        if (file is null && App.Current.HidesLiveWindowOnClose)
        {
            HideLiveWindow();
            return;
        }
        Close();
    }

    private void HideLiveWindow()
    {
        if (hasShown && !isHidden)
        {
            SavePlace();
        }
        isHidden = true;
        var goesOn = App.Current.ShowsNotificationIcon;
        if (!goesOn)
        {
            // Nothing would show that Reqly captures.
            CloseOwnWindows();
            if (capture == Capture.Capturing)
            {
                _ = StopCapturingAsync();
            }
        }
        AppWindow.Hide();
        Log(goesOn ? "the live window hid: Reqly goes on in the notification area" : "the live window hid: files are still open");
        if (goesOn)
        {
            App.Current.SayReqlyGoesOn();
        }
    }

    /// <summary>The windows this one opened, which close with it.</summary>
    private void CloseOwnWindows()
    {
        settingsWindow?.Close();
        rulesWindow?.Close();
        devicesWindow?.Close();
        welcomeWindow?.Close();
        foreach (var composer in composers.ToList())
        {
            composer.Close();
        }
    }

    /// <summary>Opens the traffic being captured: its session, and the HTTPS, rules and connections it uses.</summary>
    private async Task OpenAsync()
    {
        var openOptions = new JsonObject
        {
            ["sessionsFolder"] = options.SessionsFolder,
            ["setsSystemProxy"] = options.SetsSystemProxy,
            ["proxyRestoreFile"] = options.ProxyRestoreFile,
        };
        if (options.ProxySettingsStandIn is { } standIn)
        {
            openOptions["proxySettingsStandIn"] = standIn;
        }
        if (options.RootStandIn is { } rootStandIn)
        {
            openOptions["rootStandIn"] = rootStandIn;
            if (options.SmokeReport is not null)
            {
                // The self-check's HTTPS server, whose certificate only this run trusts.
                testServer = TestTlsServer.Start();
                openOptions["extraTrustedRoots"] = new JsonArray(Convert.ToBase64String(testServer.Authority.RawData));
            }
        }
        else
        {
            openOptions["rootFile"] = options.RootFile;
        }
        if (options.TrustRoots is { } trustRoots)
        {
            // A test run's own websites, such as the core's speed probe's.
            var roots = openOptions["extraTrustedRoots"] as JsonArray ?? [];
            var certificates = new System.Security.Cryptography.X509Certificates.X509Certificate2Collection();
            try
            {
                certificates.ImportFromPemFile(trustRoots);
            }
            catch (Exception error) when (error is IOException or System.Security.Cryptography.CryptographicException)
            {
                Log($"couldn't read the certificates to trust in {trustRoots}: {error.Message}");
            }
            foreach (var certificate in certificates)
            {
                roots.Add(Convert.ToBase64String(certificate.RawData));
            }
            openOptions["extraTrustedRoots"] = roots;
        }
        // The sidebar and the list take their first events as soon as the session opens.
        try
        {
            session = await CoreSession.OpenAsync(openOptions, DispatcherQueue);
        }
        catch (CoreProblem problem)
        {
            this.problem = problem.Message;
            ShowStatus();
            Log($"open failed: {problem.Message}");
            return;
        }
        ShowSession(session);
        https = new HttpsModel(session, settings);
        https.Changed += OnHttpsChanged;
        https.SetupRequested += () => _ = ShowSetupAsync();
        Inspector.Attach(new Inspector.InspectorContext(session, CopyText, () => WinRT.Interop.WindowNative.GetWindowHandle(this)), https);
        await https.LoadAsync();
        Log($"HTTPS: {https.Status}, {https.Hosts.Entries.Length} hosts");
        await OpenRulesAsync(session);
        await OpenConnectionsAsync(session);
        await OpenProtobufAsync(session);
        await OpenDevicesAsync(session);
        ShowStatus();
    }

    /// <summary>
    /// What Reqly does as it opens, once the live window first shows: the guide the first time,
    /// and capturing if Settings say to. Reqly opened to show files does it when you open Reqly again.
    /// </summary>
    private async Task StartAsync()
    {
        await (opening ??= OpenAsync());
        if (session is null)
        {
            return;
        }
        ShowWelcomeTheFirstTime();
        // The self-check captures from the start, whatever Settings say.
        if (capture == Capture.Stopped && (options.StartsCapturing ?? (options.SmokeReport is not null || settings.StartsCapturingOnLaunch)))
        {
            await StartCapturingAsync();
        }
        ShowStatus();
        // Opened to show files, the self-check checks that instead.
        if (options.SmokeReport is { } path && options.FilesToOpen.Count == 0)
        {
            await SelfCheckAsync(path);
        }
    }

    /// <summary>Opens a saved session or a HAR file as a session of this window's own.</summary>
    private async Task OpenFileAsync(string path)
    {
        StatusText.Text = $"Opening “{Path.GetFileName(path)}”…";
        try
        {
            session = await CoreSession.OpenAsync(new JsonObject { ["sessionsFolder"] = options.SessionsFolder, ["file"] = path }, DispatcherQueue);
        }
        catch (CoreProblem problem)
        {
            this.problem = $"Reqly couldn't open “{Path.GetFileName(path)}”. {problem.Message}";
            ShowStatus();
            Log($"couldn't open {path}: {problem.Message}");
            return;
        }
        ShowSession(session);
        ShowStatus();
    }

    /// <summary>The list, the sidebar and the filters, for the session this window shows.</summary>
    private void ShowSession(CoreSession session)
    {
        list = new RequestList(session) { ShowsEnd = IsAtEnd, Reveal = row => List.ScrollIntoView(row) };
        list.Changed += OnRowsChanged;
        List.ItemsSource = list.Rows;
        sidebar = new Sidebar(session, Navigation);
        sidebar.ScopeChanged += ShowHeading;
        Filters.Attach(session);
        Filters.ShownCount = () => list.Rows.Count;
        Filters.Changed += ShowListState;
        session.EventReceived += OnCoreEvent;
        Inspector.Attach(new Inspector.InspectorContext(session, CopyText, () => WinRT.Interop.WindowNative.GetWindowHandle(this)), null);
        // Everything listens now, so the events that came while the session opened can come too.
        session.StartEvents();
    }

    /// <summary>Puts the window back where it was, if that's still on a screen, with its panes as they were.</summary>
    private void RestorePlace()
    {
        if (settings.MainWindowPlace is { Width: > 400, Height: > 300 } place)
        {
            var area = Microsoft.UI.Windowing.DisplayArea.GetFromRect(
                new RectInt32(place.X, place.Y, place.Width, place.Height), Microsoft.UI.Windowing.DisplayAreaFallback.None);
            if (area is not null)
            {
                AppWindow.MoveAndResize(new RectInt32(place.X, place.Y, place.Width, place.Height));
                // Maximizing shows a window, so it waits until the window shows.
                showsMaximized = place.IsMaximized;
            }
        }
        if (settings.DetailsWidth is double width)
        {
            DetailsColumn.Width = new GridLength(Math.Clamp(width, DetailsColumn.MinWidth, DetailsColumn.MaxWidth));
        }
        Navigation.IsPaneOpen = settings.SidebarIsOpen;
        Traffic.ListColumns.Shared.Use(settings.ListColumnWidths);
    }

    private void SavePlace()
    {
        var isMaximized = AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter { State: Microsoft.UI.Windowing.OverlappedPresenterState.Maximized };
        // A maximized window keeps the size it had before, for when it's restored.
        if (!isMaximized || settings.MainWindowPlace is null)
        {
            settings.MainWindowPlace = new WindowPlace(AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height, isMaximized);
        }
        else
        {
            settings.MainWindowPlace = settings.MainWindowPlace with { IsMaximized = true };
        }
        settings.DetailsWidth = DetailsColumn.ActualWidth;
        settings.SidebarIsOpen = Navigation.IsPaneOpen;
        settings.ListColumnWidths = Traffic.ListColumns.Shared.Widths;
        settings.Save();
    }

    /// <summary>The port Reqly listens on: the one in Settings, unless a test run gives another.</summary>
    public int Port => options.Port ?? settings.ProxyPort;

    /// <summary>The port Reqly listens on now, while capturing.</summary>
    public int? CapturingPort => capturingPort;

    public bool SetsSystemProxy => options.SetsSystemProxy;

    /// <summary>Starting or stopping, when capturing can't be restarted yet.</summary>
    public bool IsCaptureBusy => capture is Capture.Starting or Capture.Stopping;

    public Capture CaptureState => capture;

    /// <summary>Whether the traffic being captured opened, so capturing can start.</summary>
    public bool CanCapture => file is null && session is not null;

    public HttpsModel? Https => https;

    public AppSettings Settings => settings;

    /// <summary>Capturing started or stopped, or the port changed.</summary>
    public event Action? CaptureChanged;

    /// <summary>The port in Settings. Capturing uses it the next time it starts.</summary>
    public void SetPort(int port)
    {
        if (port == settings.ProxyPort)
        {
            return;
        }
        settings.ProxyPort = port;
        settings.Save();
        Log($"port is now {port}");
        ShowStatus();
    }

    /// <summary>Stops and starts capturing again, on the port in Settings, as Restart Capturing does.</summary>
    public async Task RestartCapturingAsync()
    {
        if (capture != Capture.Capturing)
        {
            return;
        }
        await StopCapturingAsync();
        if (capture == Capture.Stopped)
        {
            await StartCapturingAsync();
        }
    }

    /// <summary>Light or dark mode: the status dots and marks follow it.</summary>
    private void UseTheme()
    {
        Palette.Use(Root.ActualTheme);
        list?.RefreshRows();
        Filters.UseTheme();
        ShowStatus();
    }

    // MARK: Settings and HTTPS

    private void OnSettingsClicked(object sender, RoutedEventArgs e) => ShowSettings();

    private void OnDecryptHttpsClicked(object sender, RoutedEventArgs e) => ShowSettings(SettingsWindow.Pane.Https);

    /// <summary>Opens Settings, on a page if one is meant. A file's window opens the main window's.</summary>
    public void ShowSettings(SettingsWindow.Pane? pane = null)
    {
        if (file is not null)
        {
            App.Current.Main?.ShowSettings(pane);
            return;
        }
        if (https is null)
        {
            return;
        }
        if (settingsWindow is null)
        {
            settingsWindow = new SettingsWindow(https, this, connections);
            settingsWindow.Closed += (_, _) => settingsWindow = null;
        }
        if (pane is { } shown)
        {
            settingsWindow.Show(shown);
        }
        settingsWindow.Activate();
    }

    private void OnSetUpHttpsClicked(object sender, RoutedEventArgs e) => _ = ShowSetupAsync();

    /// <summary>Shows HTTPS setup, unless it, or another dialog, shows already.</summary>
    private async Task ShowSetupAsync()
    {
        if (https is null || setup is not null || Root.XamlRoot is null)
        {
            return;
        }
        // It shows in this window, which may be closed into the notification area.
        if (!IsShowing)
        {
            BringForward();
        }
        setup = new HttpsSetupDialog(https, Root.XamlRoot);
        try
        {
            await setup.ShowAsync();
        }
        catch (Exception error)
        {
            // Another dialog was showing.
            Log($"setup didn't show: {error.Message}");
        }
        finally
        {
            setup = null;
        }
    }

    private void OnHttpsChanged() => ShowListState();

    // MARK: Capturing

    private async void OnCaptureClicked(object sender, RoutedEventArgs e) => await ToggleCapturingAsync();

    /// <summary>Starts or stops capturing, as the switch in the notification area's panel does.</summary>
    public async Task SetCapturingAsync(bool isOn)
    {
        if (isOn && capture == Capture.Stopped)
        {
            await StartCapturingAsync();
        }
        else if (!isOn && capture == Capture.Capturing)
        {
            await StopCapturingAsync();
        }
    }

    /// <summary>How many requests the traffic being captured has, what they sent and received, and the newest.</summary>
    public async Task<WireTrafficSummary?> SummarizeTrafficAsync()
    {
        if (session is null)
        {
            return null;
        }
        try
        {
            return Wire.Read<WireTrafficSummary>(await session.CallAsync(new JsonObject { ["call"] = "trafficSummary" }));
        }
        catch (CoreProblem problem)
        {
            Log($"couldn't sum up the traffic: {problem.Message}");
            return null;
        }
    }

    private async Task ToggleCapturingAsync()
    {
        if (capture == Capture.Capturing)
        {
            await StopCapturingAsync();
        }
        else if (capture == Capture.Stopped)
        {
            await StartCapturingAsync();
        }
    }

    private async Task StartCapturingAsync()
    {
        if (session is null || capture != Capture.Stopped)
        {
            return;
        }
        capture = Capture.Starting;
        ShowStatus();
        // Without the icon in the notification area, closing the live window stops capturing, so
        // it shows while Reqly captures.
        if (!IsShowing && !App.Current.ShowsNotificationIcon)
        {
            BringForward();
        }
        try
        {
            var result = await session.CallAsync(new JsonObject { ["call"] = "startCapturing", ["port"] = Port });
            capturingPort = result.GetProperty("port").GetInt32();
            capture = Capture.Capturing;
            problem = null;
            Log($"capturing on {capturingPort}");
            WindowsPower.KeepFullSpeed(true);
            // Reverse proxies start listening with it, unless their ports are taken.
            _ = connections?.RefreshAsync();
            if (options.SetsSystemProxy && !hasWatcher)
            {
                // If Reqly crashes now, the watcher puts your proxy settings back.
                Program.StartWatcher(options.ProxyRestoreFile);
                hasWatcher = true;
            }
        }
        catch (CoreProblem failure)
        {
            capturingPort = null;
            capture = Capture.Stopped;
            problem = $"Reqly couldn't start capturing. {failure.Message}";
            Log($"couldn't start capturing: {failure.Code}: {failure.Message}");
        }
        ShowStatus();
    }

    private async Task StopCapturingAsync()
    {
        if (session is null)
        {
            return;
        }
        capture = Capture.Stopping;
        ShowStatus();
        try
        {
            await session.CallAsync(new JsonObject { ["call"] = "stopCapturing" });
            capturingPort = null;
            capture = Capture.Stopped;
            problem = null;
            Log("stopped capturing");
            WindowsPower.KeepFullSpeed(false);
            _ = connections?.RefreshAsync();
        }
        catch (CoreProblem failure)
        {
            capture = Capture.Capturing;
            problem = $"Reqly couldn't stop capturing. {failure.Message}";
            Log($"couldn't stop capturing: {failure.Code}: {failure.Message}");
        }
        ShowStatus();
    }

    /// <summary>The Capture button, and the status bar's capture line, as on the Mac.</summary>
    private void ShowStatus()
    {
        var isCapturing = capture == Capture.Capturing;
        CaptureButton.Style = (Style)Application.Current.Resources[isCapturing ? "DefaultButtonStyle" : "AccentButtonStyle"];
        CaptureText.Text = isCapturing ? "Capturing" : "Start capturing";
        CapturingDot.Visibility = isCapturing ? Visibility.Visible : Visibility.Collapsed;
        CapturingDot.Fill = Palette.Status("success");
        CaptureButton.IsEnabled = session is not null && capture is Capture.Stopped or Capture.Capturing;
        ToolTipService.SetToolTip(CaptureButton, isCapturing ? "Stop capturing (Ctrl+R)" : "Start capturing (Ctrl+R)");
        EmptyCaptureButton.IsEnabled = CaptureButton.IsEnabled;

        StatusWarning.Visibility = Visibility.Collapsed;
        StatusFile.Visibility = Visibility.Collapsed;
        StatusDot.Visibility = Visibility.Visible;
        if (file is not null && problem is null)
        {
            StatusDot.Visibility = Visibility.Collapsed;
            StatusFile.Visibility = Visibility.Visible;
            StatusText.Text = Path.GetFileName(file);
        }
        else if (problem is not null)
        {
            StatusWarning.Visibility = Visibility.Visible;
            StatusWarning.Foreground = Palette.Failure;
            StatusDot.Visibility = Visibility.Collapsed;
            StatusText.Text = problem;
        }
        else
        {
            switch (capture)
            {
                case Capture.Capturing:
                    StatusDot.Fill = Palette.Status("success");
                    StatusText.Text = $"Capturing on port {capturingPort}" + (options.SetsSystemProxy ? "" : " · PC proxy not set") + ConnectionsNote();
                    break;
                case Capture.Starting:
                    StatusDot.Visibility = Visibility.Collapsed;
                    StatusText.Text = "Starting…";
                    break;
                case Capture.Stopping:
                    StatusDot.Visibility = Visibility.Collapsed;
                    StatusText.Text = "Stopping…";
                    break;
                default:
                    StatusDot.Fill = (Brush)Application.Current.Resources["TextFillColorTertiaryBrush"];
                    StatusText.Text = $"Not capturing · Port {Port}";
                    break;
            }
        }
        ToolTipService.SetToolTip(StatusText, file ?? (capture == Capture.Capturing && problem is null ? ConnectionsTip() ?? StatusText.Text : StatusText.Text));
        // Before any traffic, the heading says whether Reqly is capturing.
        ShowHeading();
        ShowListState();
        UpdateMenus();
        CaptureChanged?.Invoke();
    }

    // MARK: Clearing

    private async void OnClearClicked(object sender, RoutedEventArgs e) => await ClearAsync();

    /// <summary>Clears the traffic. Pinned requests stay.</summary>
    private async Task ClearAsync()
    {
        if (session is null || list is null || list.Total <= (sidebar?.Pinned ?? 0))
        {
            return;
        }
        try
        {
            await session.CallAsync(new JsonObject { ["call"] = "clear" });
        }
        catch (CoreProblem failure)
        {
            Log($"couldn't clear: {failure.Message}");
        }
    }

    // MARK: The list

    private void OnCoreEvent(JsonElement update)
    {
        switch (update.GetProperty("event").GetString())
        {
            case "rows":
                list?.Apply(update);
                break;
            case "sidebar":
            case "counts":
                sidebar?.Apply(update);
                if (sidebar?.Latest is { } latest)
                {
                    Filters.UseChoices(latest);
                }
                ShowHeading();
                ShowListState();
                break;
            case "paused":
                var held = Wire.Read<WirePaused>(update.GetProperty("paused"));
                paused[held.Id] = held;
                // It shows unless you're already looking at another one that's waiting.
                if (selectedExchange is not ulong current || !paused.ContainsKey(current) || current == held.Id)
                {
                    SelectWhenItShows(held.Id);
                }
                ShowPausedIfSelected();
                UpdateMenus();
                AskForAttention();
                break;
            case "resumed":
                paused.Remove(update.GetProperty("id").GetUInt64());
                ShowPausedIfSelected();
                UpdateMenus();
                break;
            case "deviceWaiting":
                AskForAttention();
                _ = devices?.DeviceWaitingAsync();
                break;
            case "storageProblem":
                storageProblem = update.TryGetProperty("message", out var message) && message.ValueKind == JsonValueKind.String
                    ? message.GetString()
                    : null;
                ShowHeading();
                break;
        }
    }

    /// <summary>
    /// Flashes the window's taskbar button until you come to it, as for a request held at a
    /// breakpoint. Closed into the notification area, the live window has no button, so it shows
    /// again first, behind the window you're in.
    /// </summary>
    private void AskForAttention()
    {
        if (file is null && !hasShown)
        {
            BringForward();
        }
        else if (file is null && isHidden)
        {
            isHidden = false;
            AppWindow.Show(activateWindow: false);
        }
        Attention.Ask(WinRT.Interop.WindowNative.GetWindowHandle(this));
    }

    private void OnRowsChanged()
    {
        KeepSelection();
        ShowHeading();
        ShowListState();
        UpdateMenus();
    }

    /// <summary>Whether the list shows its last row, so new rows should scroll into view.</summary>
    private bool IsAtEnd()
    {
        listScroller ??= FindScroller(List);
        return listScroller is null || listScroller.VerticalOffset >= listScroller.ScrollableHeight - 30;
    }

    private static ScrollViewer? FindScroller(DependencyObject element)
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(element); index++)
        {
            var child = VisualTreeHelper.GetChild(element, index);
            if (child is ScrollViewer scroller)
            {
                return scroller;
            }
            if (FindScroller(child) is { } found)
            {
                return found;
            }
        }
        return null;
    }

    /// <summary>The scope's title and how much of it shows, as the Mac's window title and subtitle.</summary>
    private void ShowHeading()
    {
        Heading.Text = file is not null && (sidebar?.SelectedKey ?? "all") == "all"
            ? Path.GetFileName(file)
            : sidebar?.SelectedHeading ?? "All Traffic";
        var total = list?.Total ?? 0;
        var shown = list?.Rows.Count ?? 0;
        var scopeCount = sidebar?.SelectedCount ?? total;
        Subheading.Text = storageProblem
            ?? (total == 0
                ? file is not null ? "No requests" : capture == Capture.Capturing ? "Waiting for traffic" : "Not capturing"
                : shown == scopeCount ? Format.Requests(scopeCount) : $"{shown:N0} of {Format.Requests(scopeCount)}");
        CountText.Text = total == 0 ? "" : shown == total ? Format.Requests(total) : $"{shown:N0} of {Format.Requests(total)}";
        var pinned = sidebar?.Pinned ?? 0;
        ClearButton.IsEnabled = total > pinned;
        ToolTipService.SetToolTip(
            ClearButton, pinned > 0 ? "Clear traffic (Ctrl+K). Pinned requests stay." : "Clear traffic (Ctrl+K)");
    }

    /// <summary>The list, or what to say instead: no traffic yet, or nothing that matches.</summary>
    private void ShowListState()
    {
        var total = list?.Total ?? 0;
        var shown = list?.Rows.Count ?? 0;
        var isEmpty = total == 0;
        EmptyTraffic.Visibility = isEmpty ? Visibility.Visible : Visibility.Collapsed;
        Filters.Visibility = isEmpty ? Visibility.Collapsed : Visibility.Visible;
        ListHeader.Visibility = isEmpty ? Visibility.Collapsed : Visibility.Visible;
        List.Visibility = isEmpty || shown == 0 ? Visibility.Collapsed : Visibility.Visible;
        NoMatches.Visibility = !isEmpty && shown == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (isEmpty)
        {
            ShowEmptyTraffic();
        }
        else if (shown == 0)
        {
            ShowNoMatches();
        }
    }

    private void ShowEmptyTraffic()
    {
        if (file is not null)
        {
            EmptyTitle.Text = "No requests";
            EmptyText.Text = $"“{Path.GetFileName(file)}” has no requests in it.";
            EmptyCommand.Visibility = Visibility.Collapsed;
            EmptyCaptureButton.Visibility = Visibility.Collapsed;
            EmptyShortcut.Visibility = Visibility.Collapsed;
            HttpsHint.Visibility = Visibility.Collapsed;
            return;
        }
        var isCapturing = capture == Capture.Capturing;
        EmptyTitle.Text = isCapturing ? "Waiting for traffic" : "No traffic yet";
        EmptyText.Text = (isCapturing, options.SetsSystemProxy) switch
        {
            (true, true) => "Use an app that goes online, such as Microsoft Edge. Its requests show up here.",
            (true, false) => "Reqly isn't setting your PC's proxy, so point apps at it yourself, for example:",
            (false, true) => "Start capturing to see what your apps send and receive. While capturing, Reqly is your PC's proxy. Your network settings come back when you stop.",
            (false, false) => "Start capturing to see what your apps send and receive.",
        };
        EmptyCommand.Text = $"curl -x 127.0.0.1:{capturingPort ?? Port} http://example.com";
        EmptyCommand.Visibility = isCapturing && !options.SetsSystemProxy ? Visibility.Visible : Visibility.Collapsed;
        EmptyCaptureButton.Visibility = isCapturing ? Visibility.Collapsed : Visibility.Visible;
        EmptyShortcut.Visibility = EmptyCaptureButton.Visibility;
        HttpsHint.Visibility = https is { IsTrusted: false } && https.Status != HttpsModel.Phase.Checking
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void ShowNoMatches()
    {
        var query = SearchBox.Text.Trim();
        var filtered = Filters.IsActive;
        NoMatchesIcon.Glyph = filtered ? "\uE71C" : "\uE721";
        NoMatchesTitle.Text = (filtered, query.Length > 0) switch
        {
            (_, true) => $"No results for “{query}”",
            (true, false) => "No matching requests",
            _ => "No requests",
        };
        NoMatchesText.Text = (filtered, query.Length > 0) switch
        {
            (true, true) => "No requests match both the search and the filters.",
            (true, false) => "No requests match the filters.",
            (false, true) => "Check the spelling or try a new search.",
            _ => "",
        };
        NoMatchesText.Visibility = NoMatchesText.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        ClearFiltersButton.Visibility = filtered ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void OnClearFiltersClicked(object sender, RoutedEventArgs e) => await Filters.ClearAsync();

    private async void OnSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (session is null)
        {
            return;
        }
        try
        {
            // The core narrows the list at once, and adds what it finds in headers and bodies a
            // moment later.
            await session.CallAsync(new JsonObject { ["call"] = "setSearch", ["text"] = SearchBox.Text });
        }
        catch (CoreProblem problem)
        {
            Log($"couldn't search: {problem.Message}");
        }
    }

    private void OnPaneToggleRequested(TitleBar sender, object args) => Navigation.IsPaneOpen = !Navigation.IsPaneOpen;

    // MARK: Shortcuts

    /// <summary>The Mac's shortcuts, with Ctrl for Command.</summary>
    private void AddShortcuts()
    {
        Shortcut(VirtualKey.R, VirtualKeyModifiers.Control, () =>
        {
            if (file is null)
            {
                _ = ToggleCapturingAsync();
            }
        });
        Shortcut(VirtualKey.N, VirtualKeyModifiers.Control, () => App.Current.Main?.ShowComposer(null));
        Shortcut(VirtualKey.O, VirtualKeyModifiers.Control, () => _ = PickFileToOpenAsync());
        Shortcut(VirtualKey.S, VirtualKeyModifiers.Control, () => _ = SaveSessionAsync());
        Shortcut(VirtualKey.E, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => _ = ExportHarAsync());
        Shortcut(VirtualKey.W, VirtualKeyModifiers.Control, CloseOrHide);
        Shortcut(VirtualKey.Q, VirtualKeyModifiers.Control, () => App.Current.Quit());
        Shortcut(VirtualKey.F1, VirtualKeyModifiers.None, OpenHelp);
        Shortcut(VirtualKey.K, VirtualKeyModifiers.Control, () => _ = ClearAsync());
        Shortcut(VirtualKey.F, VirtualKeyModifiers.Control, () => SearchBox.Focus(FocusState.Keyboard));
        Shortcut((VirtualKey)0xBC, VirtualKeyModifiers.Control, () => ShowSettings());
        Shortcut(VirtualKey.C, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => _ = CopyUrlAsync(SelectedRow));
        Shortcut(VirtualKey.C, VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu, () => _ = CopyCurlAsync(SelectedRow));
        if (file is null)
        {
            Shortcut(VirtualKey.B, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => ToggleRuleKind("breakpoint"));
            Shortcut(VirtualKey.T, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => ToggleRuleKind("slowNetwork"));
            Shortcut(VirtualKey.Enter, VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu, () => _ = ContinueAllPausedAsync());
            Shortcut(VirtualKey.R, VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu, () => ShowRules());
            Shortcut(VirtualKey.D, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, ShowDevices);
        }
        // The details' tabs, numbered as on the Mac, whether or not Messages shows.
        string[] tabs = ["overview", "request", "response", "raw", "timing", "messages"];
        for (var index = 0; index < tabs.Length; index++)
        {
            var tab = tabs[index];
            Shortcut(VirtualKey.Number1 + index, VirtualKeyModifiers.Control, () => Inspector.ShowTab(tab));
        }
    }

    private void Shortcut(VirtualKey key, VirtualKeyModifiers modifiers, Action action)
    {
        var shortcut = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
        shortcut.Invoked += (_, args) =>
        {
            args.Handled = true;
            action();
        };
        Root.KeyboardAccelerators.Add(shortcut);
    }

    private void Log(string line)
    {
        report.AppendLine(line);
        AppLog.Write(line);
    }
}
