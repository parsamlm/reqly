using System.Diagnostics;
using System.Net;
using System.Net.Security;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Reqly.Core;
using Reqly.Https;
using Reqly.Rules;
using Reqly.Settings;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Reqly;

/// <summary>
/// The self-check, for test runs: with <c>--smoke &lt;file&gt;</c>, Reqly sends requests through itself,
/// writes what happened to the file, saves pictures of its windows next to it, and quits.
/// </summary>
public sealed partial class MainWindow
{
    private async Task SelfCheckAsync(string path)
    {
        try
        {
            bool Runs(string part) => options.SmokeParts is not { } parts || parts.Contains(part);
            if (Runs("capture"))
            {
                await CheckCapturingAsync(path);
            }
            if (Runs("https"))
            {
                await CheckHttpsAsync(path);
            }
            if (Runs("connections"))
            {
                await CheckConnectionsAsync(path);
            }
            if (Runs("devices"))
            {
                await CheckDevicesAsync(path);
            }
            if (Runs("welcome"))
            {
                await CheckWelcomeAsync(path);
            }
            if (Runs("sessions"))
            {
                await CheckSessionFromElsewhereAsync(path);
            }
            if (Runs("tray"))
            {
                await CheckNotificationAreaAsync(path);
            }
            if (Runs("about"))
            {
                await CheckAboutAsync(path);
            }
            // Only when asked for by name, after a run that crashed on purpose (--smoke-crash).
            if (options.SmokeParts?.Contains("crash-report") == true)
            {
                await CheckCrashReportAsync(path);
            }
            // Only when asked for by name, in a release build: it sends thousands of requests.
            if (options.SmokeParts?.Contains("speed") == true)
            {
                await CheckSpeedAsync(path);
            }
            if (options.SmokeParts?.Contains("serve") == true)
            {
                await ServeAsync(path);
            }
            Log($"memory: {Process.GetCurrentProcess().WorkingSet64 / 1048576} MB");
        }
        catch (Exception error)
        {
            Log($"error: {error}");
        }
        File.WriteAllText(path, report.ToString());
        App.Current.Quit();
    }

    /// <summary>
    /// Opens the panel that Reqly's icon in the notification area opens, as clicking the icon does,
    /// flips its switches, then closes the live window as its close button does: Reqly goes on
    /// capturing in the notification area, and the panel's Open Reqly shows the window again.
    /// </summary>
    private async Task CheckNotificationAreaAsync(string path)
    {
        var app = App.Current;
        Log($"notification area: icon {app.DescribeNotificationIcon()}");
        if (!app.ShowsNotificationIcon)
        {
            return;
        }
        if (app.NotificationIconBounds is { } icon)
        {
            await SavePictureOfScreenAsync(new Windows.Graphics.RectInt32(icon.X - 64, icon.Y, icon.Width + 128, icon.Height), path + ".icon-screen.png");
        }
        app.ClickNotificationIcon();
        await WaitForAsync(() => app.NotificationPanel?.IsOpen == true, 5);
        if (app.NotificationPanel is not { IsOpen: true } panel)
        {
            Log("panel: clicking the icon didn't open it");
            return;
        }
        await Task.Delay(1200);
        Log($"panel: {panel.Describe()}");
        await SaveScreenshotAsync(panel.View, path + ".panel.png");
        await SavePictureOfScreenAsync(panel, path + ".panel-screen.png");
        // Clicking the icon again closes it, and once more, a moment later, opens it.
        app.ClickNotificationIcon();
        var closed = await WaitForAsync(() => !panel.IsOpen, 5);
        await Task.Delay(600);
        app.ClickNotificationIcon();
        var opened = await WaitForAsync(() => panel.IsOpen, 5);
        Log($"clicking the icon again: the panel {(closed ? "closed" : "stayed open")}, and once more: it {(opened ? "opened" : "stayed closed")}");

        // Slow Network on and off, which doesn't open the Rules window as Breakpoints with no rules does.
        panel.Flip("slowNetwork");
        await Task.Delay(800);
        Log($"Slow Network from the panel: {(rules?.IsOn("slowNetwork") == true ? "on" : "off")}, toolbar {(SlowNetworkButton.IsChecked == true ? "on" : "off")}");
        panel.Flip("slowNetwork");
        await Task.Delay(800);
        Log($"and again: {(rules?.IsOn("slowNetwork") == true ? "on" : "off")}");

        panel.Flip("capture");
        await WaitForAsync(() => capture == Capture.Stopped, 10);
        Log($"stopped from the panel: {panel.Describe()} · icon {app.DescribeNotificationIcon()}");
        panel.Flip("capture");
        await WaitForAsync(() => capture == Capture.Capturing, 10);
        Log($"started from the panel: status {StatusText.Text} · icon {app.DescribeNotificationIcon()}");
        panel.Dismiss();

        // Its close button sends this.
        PostMessage(WinRT.Interop.WindowNative.GetWindowHandle(this), 0x0010, 0, 0);
        var hidden = await WaitForAsync(() => !IsShowing, 10);
        Log($"closed the live window: it {(hidden ? "hid" : "still shows")}, capture {capture}, said where Reqly went: {settings.HasSaidItGoesOn}");
        if (capturingPort is int port)
        {
            using var client = Client(port);
            using var response = await client.GetAsync("http://weather.invalid/v2/forecast?city=Tabriz");
            Log($"a request while it's hidden: {(int)response.StatusCode}");
            await CheckHeldWhileHiddenAsync(port);
        }
        // A click right after the panel closes doesn't open it again.
        await Task.Delay(600);
        app.ClickNotificationIcon();
        await WaitForAsync(() => panel.IsOpen, 5);
        await Task.Delay(1200);
        Log($"panel with the window closed: {panel.Describe()}");
        await SavePictureOfScreenAsync(panel, path + ".panel-hidden-screen.png");
        panel.ChooseOpen();
        var shown = await WaitForAsync(() => IsShowing, 10);
        Log($"Open Reqly from the panel: the live window {(shown ? "shows" : "stays hidden")}, panel {(panel.IsOpen ? "open" : "closed")}");

        // As the switch in Settings › General does.
        app.SetShowsNotificationIcon(false);
        Log($"icon turned off: {app.DescribeNotificationIcon()}, closing the window would {(app.HidesLiveWindowOnClose ? "hide it" : "quit Reqly")}");
        app.SetShowsNotificationIcon(true);
        Log($"and on again: {app.DescribeNotificationIcon()}, closing the window would {(app.HidesLiveWindowOnClose ? "hide it" : "quit Reqly")}");
    }

    /// <summary>
    /// Holds a request at a breakpoint while the live window is closed into the notification area:
    /// the window shows again, behind the one you're in, then closes again once the request goes on.
    /// </summary>
    private async Task CheckHeldWhileHiddenAsync(int port)
    {
        if (rules is null)
        {
            Log("held while hidden: not checked");
            return;
        }
        var draft = await rules.NewDraftAsync("breakpoint");
        draft.Name = "Hold while hidden";
        draft.Host = "weather.invalid";
        draft.Phase = "request";
        await rules.SaveAsync(draft);
        await rules.SetOnAsync("breakpoint", true);
        using var client = Client(port);
        var fetching = client.GetAsync("http://weather.invalid/v2/held-while-hidden");
        var held = await WaitForAsync(() => paused.Count > 0, 10);
        var shown = await WaitForAsync(() => IsShowing, 5);
        var front = GetForegroundWindow() == WinRT.Interop.WindowNative.GetWindowHandle(this);
        await ContinueAllPausedAsync();
        var wentOn = await Task.WhenAny(fetching, Task.Delay(8000)) == fetching;
        Log($"held while hidden: {(held ? "held" : "not held")}, the live window {(shown ? "shows" : "stays hidden")}{(front ? ", in front" : ", behind")}, " +
            $"and the request {(wentOn ? "went on" : "was still held")}");
        await rules.SetOnAsync("breakpoint", false);
        foreach (var rule in rules.Rules.Rules)
        {
            await rules.RemoveAsync(rule.Id);
        }
        if (wentOn)
        {
            (await fetching).Dispose();
        }
        PostMessage(WinRT.Interop.WindowNative.GetWindowHandle(this), 0x0010, 0, 0);
        await WaitForAsync(() => !IsShowing, 10);
    }

    /// <summary>
    /// Opens About Reqly as the Help menu does, its license, and the open-source licenses, with the
    /// packages whose notices Reqly for Windows alone carries.
    /// </summary>
    private async Task CheckAboutAsync(string path)
    {
        App.Current.ShowAbout(this);
        await WaitForAsync(() => App.Current.About?.Visible == true, 5);
        if (App.Current.About is not { } about)
        {
            Log("about: it didn't open");
            return;
        }
        await Task.Delay(1000);
        Log($"about: {about.Describe()}");
        await SaveScreenshotAsync(about.View, path + ".about.png");
        // On the screen too, for its title bar, which the window's own picture leaves out: above
        // other windows for a moment, since a test run may open behind them.
        if (about.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
        {
            presenter.IsAlwaysOnTop = true;
            await Task.Delay(500);
            await SavePictureOfScreenAsync(about, path + ".about-screen.png");
            presenter.IsAlwaysOnTop = false;
        }
        Log($"about's title bar: {about.AppWindow.TitleBar.PreferredTheme}");
        var showing = about.ShowLicenseAsync();
        await Task.Delay(1000);
        if (about.LicenseView is { } license)
        {
            await SaveScreenshotAsync(license, path + ".license.png");
        }
        Log($"license: {(Help.AppInfo.LicenseText is { } text ? $"{text.Split('\n')[0].Trim()}, {text.Length:N0} characters" : "missing")}");
        about.HideLicense();
        await showing;
        var licenses = about.ShowOpenSourceLicenses();
        await Task.Delay(1500);
        Log($"open-source licenses: {licenses.Describe()}");
        await SaveScreenshotAsync(licenses.View, path + ".licenses.png");
        foreach (var name in new[] { "swift-nio-ssl", "SQLite", "zlib", "Velopack", "WebView2" })
        {
            licenses.Choose(name);
            await Task.Delay(700);
            Log($"  {licenses.Describe()}");
        }
        await SaveScreenshotAsync(licenses.View, path + ".licenses-webview2.png");
        about.Close();
        var closed = await WaitForAsync(() => App.Current.About is null, 5);
        Log($"closing About: {(closed ? "both windows closed" : "it stayed open")}");

        // Help › Check for updates…, which a test run answers at once, since it doesn't update.
        var checking = ShowUpdatesAsync();
        if (!await WaitForAsync(() => Updates.UpdateDialog.Showing is not null, 5) || Updates.UpdateDialog.Showing is not { } updates)
        {
            Log("check for updates: the dialog didn't show");
            return;
        }
        await Task.Delay(800);
        Log($"check for updates: {(updates.Content as TextBlock)?.Text} · buttons: {updates.PrimaryButtonText}|{updates.CloseButtonText}");
        await SavePictureOfScreenAsync(this, path + ".updates-screen.png");
        updates.Hide();
        await checking;
        Log($"closing it: {(Updates.UpdateDialog.Showing is null ? "closed" : "still open")}");
    }

    /// <summary>
    /// The offer to report the crash of the run before, which crashed on purpose: what the report
    /// says, its link, and pictures, then Report on GitHub, which a test run only logs.
    /// </summary>
    private async Task CheckCrashReportAsync(string path)
    {
        if (!await WaitForAsync(() => App.Current.CrashReport is not null, 20) || App.Current.CrashReport is not { } offer)
        {
            Log("crash report: none offered");
            return;
        }
        await Task.Delay(1000);
        Log($"crash report: {offer.Describe()}");
        foreach (var line in offer.Body.Split('\n'))
        {
            Log($"  | {line}");
        }
        await SaveScreenshotAsync(offer.View, path + ".crash-report.png");
        // On the screen too, with its title bar, above other windows for a moment.
        if (offer.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
        {
            presenter.IsAlwaysOnTop = true;
            await Task.Delay(500);
            await SavePictureOfScreenAsync(offer, path + ".crash-report-screen.png");
            presenter.IsAlwaysOnTop = false;
        }
        Log($"report a problem: a new issue, {CrashReports.CrashReporter.ProblemUrl.AbsoluteUri.Length:N0} characters long");
        offer.Report();
        var closed = await WaitForAsync(() => App.Current.CrashReport is null, 5);
        Log($"report on GitHub: {(closed ? "the window closed" : "it stayed open")}");
        Log($"crash files kept: {string.Join(", ", Directory.EnumerateFiles(options.CrashReportsFolder).Select(Path.GetFileName))}");
    }

    /// <summary>A picture of the screen where a window is, with a little around it, as it shows.</summary>
    private Task SavePictureOfScreenAsync(Window window, string path)
    {
        const int margin = 24;
        return SavePictureOfScreenAsync(new Windows.Graphics.RectInt32(
            window.AppWindow.Position.X - margin, window.AppWindow.Position.Y - margin,
            window.AppWindow.Size.Width + 2 * margin, window.AppWindow.Size.Height + 2 * margin), path);
    }

    private async Task SavePictureOfScreenAsync(Windows.Graphics.RectInt32 area, string path)
    {
        try
        {
            await Smoke.ScreenPicture.SaveAsync(area, path);
            Log($"picture: {Path.GetFileName(path)}, {area.Width}x{area.Height} of the screen");
        }
        catch (Exception error)
        {
            Log($"couldn't take a picture of the screen: {error.Message}");
        }
    }

    /// <summary>
    /// Sends a request through Reqly from Reqly itself, so the app the list shows is Reqly; then
    /// selects it, searches, and stops and starts capturing, as the Capture button does.
    /// </summary>
    private async Task CheckCapturingAsync(string path)
    {
        if (capturingPort is int port)
        {
            using var client = Client(port);
            var watch = Stopwatch.StartNew();
            // .invalid never resolves, so Reqly answers itself and nothing leaves the computer.
            using var response = await client.GetAsync("http://weather.invalid/v2/forecast?city=Tehran");
            Log($"request: {(int)response.StatusCode} in {watch.ElapsedMilliseconds} ms");
        }
        await Task.Delay(1500);
        Log($"rows: {list?.Rows.Count} of {list?.Total}");
        if (list?.Rows.FirstOrDefault() is { } first)
        {
            Log($"first row: {first.Status} {first.Method} {first.DisplayHost}{first.Rest} · app {first.App} · icon {first.AppIcon is not null}");
            List.SelectedItem = first;
            await Task.Delay(1500);
            Log($"details: {Inspector.Describe()}");
        }
        SearchBox.Text = "Tehran";
        await Task.Delay(800);
        Log($"searching for Tehran: {list?.Rows.Count} rows");
        SearchBox.Text = "nothing-has-this";
        await Task.Delay(800);
        Log($"searching for nothing-has-this: {list?.Rows.Count} rows");
        SearchBox.Text = "";
        await Task.Delay(800);
        Log($"status: {StatusText.Text} · {CountText.Text}");
        await SaveScreenshotAsync(Root, path + ".png");
        await StopCapturingAsync();
        ShowStatus();
        Log($"after stopping: {StatusText.Text}");
        await StartCapturingAsync();
        ShowStatus();
        Log($"after starting again: {StatusText.Text}");
        if (capturingPort is int again)
        {
            using var client = Client(again);
            using var response = await client.GetAsync("http://weather.invalid/v2/forecast?city=Lisbon");
            await Task.Delay(1000);
            Log($"second request: {(int)response.StatusCode}; rows {list?.Rows.Count} of {list?.Total}");
        }
    }

    /// <summary>
    /// Sets up HTTPS with the stand-in certificate, decrypts a request to the self-check's own
    /// HTTPS server, then lets the next one through encrypted. It runs only with
    /// <c>--root-stand-in</c>, so Windows' certificate stores are never touched.
    /// </summary>
    private async Task CheckHttpsAsync(string path)
    {
        if (https is null || testServer is null || options.RootStandIn is null || capturingPort is not int port)
        {
            Log("HTTPS: not checked, since this run has no stand-in certificate");
            return;
        }
        Log($"HTTPS at first: {https.Status}");
        await SaveSettingsPictureAsync(path + ".settings-general.png", SettingsWindow.Pane.General);
        await SaveSettingsPictureAsync(path + ".settings-before.png", SettingsWindow.Pane.Https);
        setup = new HttpsSetupDialog(https, Root.XamlRoot);
        var showing = setup.ShowAsync();
        await Task.Delay(1000);
        await SaveScreenshotAsync(setup.View, path + ".setup.png");
        await https.SetUpAsync();
        setup.Hide();
        await showing;
        setup = null;
        Log($"HTTPS after setup: {https.Status} · {https.Certificate?.Name}");
        Log($"adding “not a host”: {await https.AddHostAsync("not a host")}");
        var added = await https.AddHostAsync("localhost");
        Log($"adding localhost: {added ?? "added"} · hosts: {Hosts()}");
        Log($"settings file: {File.ReadAllText(options.SettingsFile).ReplaceLineEndings(" ")}");

        using var root = X509CertificateLoader.LoadCertificate(https.CertificateForDevices!);
        var url = $"https://localhost:{testServer.Port}/v1/forecast?city=Lisbon";
        var issuer = "";
        using (var client = Client(port, [root, testServer.Authority], seen => issuer = seen))
        {
            using var response = await client.GetAsync(url);
            Log($"decrypted request: {(int)response.StatusCode} {await response.Content.ReadAsStringAsync()} · certificate from {issuer}");
        }
        await Task.Delay(1500);
        if (list?.Rows.FirstOrDefault(row => row.Host == "localhost" && !row.IsTunnel) is { } decrypted)
        {
            List.SelectedItem = decrypted;
            await Task.Delay(1500);
            Log($"decrypted row: {decrypted.Status} {decrypted.Method} {decrypted.Rest} · {Inspector.Describe()}");
            Log($"note: {Inspector.DecryptionNoteText}");
            await SaveScreenshotAsync(Root, path + ".decrypted.png");
            // Each tab, as the shortcuts show them.
            foreach (var tab in new[] { "request", "response", "raw", "timing" })
            {
                Inspector.ShowTab(tab);
                await Task.Delay(900);
                Log($"{tab} tab: {Inspector.ContentText().ReplaceLineEndings(" ")}");
                await SaveScreenshotAsync(Root, path + $".{tab}.png");
            }
            Inspector.ShowTab("overview");
            await Task.Delay(500);
        }
        else
        {
            Log("decrypted row: missing");
        }
        await CheckListAsync(path, port, [root, testServer.Authority]);

        await https.StopDecryptingAsync("localhost");
        Log($"stopped decrypting localhost · hosts: {Hosts()}");
        using (var client = Client(port, [root, testServer.Authority], seen => issuer = seen))
        {
            using var response = await client.GetAsync(url);
            Log($"encrypted request: {(int)response.StatusCode} · certificate from {issuer}");
        }
        await Task.Delay(1500);
        if (list?.Rows.FirstOrDefault(row => row.Host == "localhost" && row.IsTunnel) is { } tunnel)
        {
            List.SelectedItem = tunnel;
            await Task.Delay(1500);
            // The note is on the Overview, which an earlier check may have left for another tab.
            // Tabs change only while a request shows, so this comes after choosing the row.
            Inspector.ShowTab("overview");
            await Task.Delay(900);
            Log($"tunnel row: {tunnel.Rest.Trim()} · lock {tunnel.LockVisibility} · {Inspector.Describe()}");
            Log($"note: {Inspector.DecryptionNoteText}");
            await SaveScreenshotAsync(Root, path + ".tunnel.png");
        }
        else
        {
            Log("tunnel row: missing");
        }

        await SaveSettingsPictureAsync(path + ".settings.png", SettingsWindow.Pane.Https);
        await https.RemoveAsync();
        Log($"HTTPS after removing: {https.Status} · stand-in left: {File.Exists(options.RootStandIn)}");

        // As Reqly is uninstalled: set up again, then removed the way the uninstaller removes it.
        await https.SetUpAsync();
        var made = File.Exists(options.RootStandIn);
        var removal = Core.CoreSession.RemoveRoot(options.RootStandIn!, standIn: true);
        var again = Core.CoreSession.RemoveRoot(options.RootStandIn!, standIn: true);
        Log($"uninstalling: the certificate was there {made}, removing it: {removal}, stand-in left: {File.Exists(options.RootStandIn)}, again: {again}");
        await https.RemoveAsync();
    }

    /// <summary>
    /// Adds a reverse proxy, which listens on this PC only, and checks it listens while capturing;
    /// checks an upstream proxy without applying it; and pictures the connection pages.
    /// </summary>
    private async Task CheckConnectionsAsync(string path)
    {
        if (connections is null)
        {
            Log("connections: not checked");
            return;
        }
        var proxy = await connections.NewReverseProxyAsync();
        // .invalid never resolves, and nothing is sent to it: the check only listens.
        var saved = await connections.SaveReverseProxyAsync(proxy with { ServerURL = "https://weather.invalid" });
        await Task.Delay(500);
        var rows = connections.Connections.ReverseProxies.Select(row => $"{row.LocalAddress} → {row.Server} {row.Problem ?? "listening"}");
        Log($"reverse proxy: {saved ?? "saved"} · {string.Join(", ", rows)} · status “{StatusText.Text}”");
        var own = connections.Connections.UpstreamProxy with { IsOn = true, Host = "127.0.0.1", Port = Port.ToString(System.Globalization.CultureInfo.InvariantCulture) };
        Log($"upstream proxy at Reqly's own address: {await connections.CheckUpstreamProxyAsync(own) ?? "no problem"}");
        Log($"upstream proxy without a server: {await connections.CheckUpstreamProxyAsync(own with { Host = "" }) ?? "no problem"}");
        foreach (var (pane, name) in new[] { (SettingsWindow.Pane.UpstreamProxy, "upstream"), (SettingsWindow.Pane.ReverseProxy, "reverse"), (SettingsWindow.Pane.ClientCertificates, "certificates") })
        {
            await SaveSettingsPictureAsync($"{path}.settings-{name}.png", pane);
        }
        foreach (var row in connections.Connections.ReverseProxies)
        {
            await connections.RemoveReverseProxyAsync(row.Id);
        }
        Log($"reverse proxies after: {connections.Connections.ReverseProxies.Length}");
    }

    /// <summary>
    /// Pictures the Devices window with devices left off, and a setup code for an address kept for
    /// documentation. Nothing listens on the network, and adb never runs.
    /// </summary>
    private async Task CheckDevicesAsync(string path)
    {
        if (devices is null)
        {
            Log("devices: not checked");
            return;
        }
        ShowDevices();
        await Task.Delay(1500);
        if (devicesWindow is { } window)
        {
            Log($"devices: {(window.PageView as Devices.PhonesView)?.Describe()} · status “{StatusText.Text}”");
            await SaveScreenshotAsync(window.View, path + ".devices.png");
            window.Close();
        }
        // As wide as the Phones page's cards, over the window for a moment, since its cards show the code only while devices are allowed.
        var preview = new Border
        {
            Child = Devices.PhonesView.CodePreview(this, devices, "http://192.0.2.1:9191/"),
            Width = 680,
            Padding = new Thickness(20),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            Background = global::Reqly.Inspector.Blocks.Resource("ApplicationPageBackgroundThemeBrush"),
        };
        Grid.SetRowSpan(preview, Root.RowDefinitions.Count);
        Root.Children.Add(preview);
        await Task.Delay(1000);
        await SaveScreenshotAsync(preview, path + ".setup-code.png");
        Root.Children.Remove(preview);
        await CheckSidebarWithDeviceAsync(path);
    }

    /// <summary>
    /// The sidebar as a device's traffic comes and goes, which the self-check can't make, since it
    /// lets no device in: the core's own "sidebar" events, made up from the session's rows. This
    /// PC's apps go under This PC, beside the device, and back to the top, three times, the last
    /// two with an app's row selected.
    /// </summary>
    private async Task CheckSidebarWithDeviceAsync(string path)
    {
        if (sidebar?.Latest is not { } real)
        {
            Log("sidebar with a device: not checked");
            return;
        }
        WireSidebarRow[] apps = real.Apps.Length > 0 ? real.Apps : [new("app\u001f\u001fSelf-check\u001f\u001f", "Self-check", 1, null)];
        var phone = "self-check-phone";
        var withDevice = real with
        {
            Apps = apps,
            Devices =
            [
                new("device\u001f", "", null, null, apps.Sum(app => app.Count), apps, []),
                new($"device\u001f{phone}", phone, "Self-check phone", "network", 1, [], [new($"deviceHost\u001f{phone}\u001fphone.invalid", "phone.invalid", 1, null)]),
            ],
        };
        var withoutDevice = real with { Apps = apps, Devices = [] };
        void Show(WireSidebar shown)
        {
            var update = JsonSerializer.SerializeToNode(shown, Wire.Options)!.AsObject();
            update["event"] = "sidebar";
            using var document = JsonDocument.Parse(update.ToJsonString());
            sidebar.Apply(document.RootElement);
        }
        for (var round = 1; round <= 3; round++)
        {
            if (round > 1)
            {
                sidebar.Select(apps[0].Key);
            }
            Show(withDevice);
            await Task.Delay(500);
            Log($"sidebar with a device, round {round}: {sidebar.Describe()}");
            Show(withoutDevice);
            await Task.Delay(500);
            Log($"sidebar without it, round {round}: {sidebar.Describe()}");
        }
        sidebar.Select("all");
        Show(real);
        await Task.Delay(300);
        Log($"sidebar as the session has it: {sidebar.Describe()}");
    }

    /// <summary>
    /// Makes a rule of each kind in the Rules window's editor, then sends requests each one acts on:
    /// Map Local answers with a file, Block with a status or by closing the connection, Map Remote
    /// sends to another page of the self-check's server, and Rewrite and a script change responses.
    /// Nothing leaves this PC: the rest go to .invalid hosts, which never resolve.
    /// </summary>
    private async Task CheckRuleKindsAsync(string path, int port, X509Certificate2[] trusted)
    {
        if (rules is null || testServer is null || session is null || ShowRules("mapLocal") is not { } window)
        {
            Log("rule kinds: not checked");
            return;
        }
        await Task.Delay(1000);
        var server = $"localhost:{testServer.Port}";
        var file = path + ".maplocal.json";
        await File.WriteAllTextAsync(file, """{"city":"Tehran","from":"Map Local"}""");
        async Task SaveAsync(string kind, Action<WireRuleDraft> fill, string? picture = null)
        {
            var draft = await rules.NewDraftAsync(kind);
            fill(draft);
            var editing = window.EditAsync(draft);
            await Task.Delay(1200);
            if (window.Editor is not RuleEditorDialog editor)
            {
                Log($"{kind} editor: didn't show");
                return;
            }
            Log($"{kind} editor: {editor.Describe()}");
            if (picture is not null)
            {
                await SaveScreenshotAsync(editor, $"{path}.rule-{picture}.png");
            }
            var problem = await rules.SaveAsync(draft);
            editor.Hide();
            await editing;
            Log($"saved {kind}: {problem ?? "fine"}");
        }
        await SaveAsync("mapLocal", draft =>
        {
            draft.Host = "weather.invalid";
            draft.Path = "/v2/local";
            draft.File = file;
            draft.ContentType = "application/json";
        }, "maplocal");
        await SaveAsync("block", draft =>
        {
            draft.Host = "weather.invalid";
            draft.Path = "/v2/blocked";
            draft.BlockStatus = 451;
        });
        await SaveAsync("block", draft =>
        {
            draft.Name = "Close the connection";
            draft.Host = "weather.invalid";
            draft.Path = "/v2/closed";
            draft.ClosesConnection = true;
        }, "block");
        await SaveAsync("mapRemote", draft =>
        {
            draft.Host = server;
            draft.Path = "/v1/remote";
            draft.Destination = $"https://{server}/v1/missing";
        });
        await SaveAsync("rewrite", draft =>
        {
            draft.Host = server;
            draft.Path = "/v1/rewritten";
            draft.Changes =
            [
                new WireRewriteChange { Change = "setStatus", Status = 299 },
                new WireRewriteChange { Change = "setHeader", Part = "response", Name = "X-Reqly", Value = "rewritten" },
                new WireRewriteChange { Change = "replaceBody", Part = "response", Name = "Lisbon", Value = "Tehran" },
            ];
        }, "rewrite");
        var scripted = await rules.NewDraftAsync("script");
        scripted.Host = server;
        scripted.Path = "/v1/scripted";
        scripted.Code = "function onResponse(response, request) {\n  response.headers.set(\"X-Script\", \"ran\");\n  console.log(\"scripted\", response.status);\n}\n";
        Log($"saved script: {await rules.SaveAsync(scripted) ?? "fine"}");
        Log($"rules: {string.Join(", ", rules.Rules.Rules.Select(rule => $"{rule.Kind} {rule.Name} [{rule.Tag}]"))} · on: {string.Join(", ", rules.Rules.KindsOn)}");
        window.Show("block");
        await Task.Delay(800);
        Log($"rules window: {window.Describe()}");
        await SaveScreenshotAsync(window.View, path + ".rules-block.png");

        using (var client = Client(port, trusted))
        {
            async Task<string> FetchAsync(string url)
            {
                try
                {
                    using var response = await client.GetAsync(url);
                    var marks = string.Join(" ", response.Headers.Where(header => header.Key.StartsWith("X-", StringComparison.Ordinal))
                        .Select(header => $"{header.Key}: {string.Join(",", header.Value)}"));
                    return $"{(int)response.StatusCode} {marks} {await response.Content.ReadAsStringAsync()}".Trim();
                }
                catch (HttpRequestException error)
                {
                    return $"failed: {error.HttpRequestError}";
                }
            }
            Log($"map local: {await FetchAsync("http://weather.invalid/v2/local")}");
            Log($"block: {await FetchAsync("http://weather.invalid/v2/blocked")}");
            Log($"block by closing: {await FetchAsync("http://weather.invalid/v2/closed")}");
            Log($"map remote: {await FetchAsync($"https://{server}/v1/remote")}");
            Log($"rewrite: {await FetchAsync($"https://{server}/v1/rewritten")}");
            Log($"script: {await FetchAsync($"https://{server}/v1/scripted")}");
        }
        await Task.Delay(1500);
        if (list?.Rows.LastOrDefault(row => row.Rest.Contains("/v1/scripted")) is { } row)
        {
            var details = Wire.Read<WireDetails>(await session.CallAsync(new JsonObject { ["call"] = "details", ["id"] = row.ID }));
            Log($"script's exchange: rules {string.Join(", ", details.AppliedRules.Select(rule => $"{rule.Kind}: {rule.Detail}"))} · output {string.Join(" / ", details.ScriptOutput.SelectMany(output => output.Lines))}");
            List.SelectedItem = row;
            await Task.Delay(1500);
            await SaveScreenshotAsync(Root, path + ".scripted.png");
        }
        foreach (var rule in rules.Rules.Rules)
        {
            await rules.RemoveAsync(rule.Id);
        }
        foreach (var kind in rules.Rules.KindsOn.ToList())
        {
            await rules.SetOnAsync(kind, false);
        }
        window.Close();
        Log($"rules after: {rules.Rules.Rules.Length}, on: {string.Join(", ", rules.Rules.KindsOn)}");
    }

    /// <summary>
    /// Adds a folder of .proto files, then reads a protobuf response from the self-check's server
    /// by number, and as the message type chosen for it.
    /// </summary>
    private async Task CheckProtobufAsync(string path, int port, X509Certificate2[] trusted)
    {
        if (protobuf is null || testServer is null || session is null)
        {
            Log("protobuf: not checked");
            return;
        }
        var folder = path + "-protos";
        Directory.CreateDirectory(Path.Combine(folder, "weather", "v1"));
        await File.WriteAllTextAsync(
            Path.Combine(folder, "weather", "v1", "forecast.proto"),
            "syntax = \"proto3\";\npackage weather.v1;\nmessage Forecast { string city = 1; int32 days = 2; }\nmessage Hour { int32 hour = 1; }\n");
        await protobuf.AddAsync([folder]);
        Log($"protobuf: {string.Join(", ", protobuf.Protobuf.Sources.Select(source => $"{source.Name} {source.Count}"))} · {protobuf.Protobuf.Summary} · types {string.Join(" ", protobuf.Protobuf.Types)}");
        using (var client = Client(port, trusted))
        {
            using var response = await client.GetAsync($"https://localhost:{testServer.Port}/v1/proto");
            Log($"protobuf response: {(int)response.StatusCode} {response.Content.Headers.ContentType}");
        }
        await Task.Delay(1500);
        if (list?.Rows.LastOrDefault(row => row.Rest.Contains("/v1/proto")) is not { } row)
        {
            Log("protobuf: the row didn't show");
            return;
        }
        async Task<string> DescribeBodyAsync()
        {
            var body = Wire.Read<WireBody>(await session.CallAsync(new JsonObject { ["call"] = "presentBody", ["id"] = row.ID, ["part"] = "response" }));
            var labels = body.Tree?.Nodes.Select(node => node.Label).Where(label => label.Length > 0).Take(6) ?? [];
            return $"protobuf {body.ReadsAsProtobuf}, type {body.ProtobufType ?? "none"}, chosen {body.ChosenType ?? "none"}, has types {body.HasMessageTypes}, tree {string.Join(" ", labels)}";
        }
        Log($"protobuf body by number: {await DescribeBodyAsync()}");
        List.SelectedItem = row;
        await Task.Delay(800);
        Inspector.ShowTab("response");
        await Task.Delay(1500);
        await SaveScreenshotAsync(Root, path + ".protobuf-number.png");
        await ProtobufModel.ChooseAsync(session, row.ID, isRequest: false, "weather.v1.Forecast");
        Log($"protobuf body as Forecast: {await DescribeBodyAsync()}");
        await Inspector.ShowAsync(row.ID);
        await Task.Delay(1500);
        await SaveScreenshotAsync(Root, path + ".protobuf-type.png");
        await SaveSettingsPictureAsync(path + ".settings-protobuf.png", SettingsWindow.Pane.Protobuf);
        await ProtobufModel.ChooseAsync(session, row.ID, isRequest: false, null);
        foreach (var source in protobuf.Protobuf.Sources)
        {
            await protobuf.RemoveAsync(source.Path);
        }
        Log($"protobuf after: {protobuf.Protobuf.Sources.Length} sources");
    }

    /// <summary>Reads a response that the self-check's server packs with Brotli, as many servers do.</summary>
    private async Task CheckBrotliAsync(string path, int port, X509Certificate2[] trusted)
    {
        if (testServer is null || session is null)
        {
            Log("brotli: not checked");
            return;
        }
        using (var client = Client(port, trusted))
        {
            using var response = await client.GetAsync($"https://localhost:{testServer.Port}/v1/brotli");
            Log($"brotli response: {(int)response.StatusCode} {string.Join(",", response.Content.Headers.ContentEncoding)} · {response.Content.Headers.ContentLength} bytes");
        }
        await Task.Delay(1500);
        if (list?.Rows.LastOrDefault(row => row.Rest.Contains("/v1/brotli")) is not { } row)
        {
            Log("brotli: the row didn't show");
            return;
        }
        var body = Wire.Read<WireBody>(await session.CallAsync(new JsonObject { ["call"] = "presentBody", ["id"] = row.ID, ["part"] = "response" }));
        Log($"brotli body: {body.Kind} · {body.Size} B from {body.WireSize} B, unpacked from {body.UnpackedFrom ?? "nothing"} · {body.Formatted?.Text.ReplaceLineEndings(" ")}");
        List.SelectedItem = row;
        await Task.Delay(800);
        Inspector.ShowTab("response");
        await Task.Delay(1500);
        await SaveScreenshotAsync(Root, path + ".brotli.png");
    }

    /// <summary>
    /// Opens a session another system saved, such as the one Reqly for Mac 1.0 saved for the core's
    /// tests, in a window of its own, and shows some of its requests there: an app's, a device's,
    /// bodies packed and plain, a picture, WebSocket messages and Persian text.
    /// </summary>
    private async Task CheckSessionFromElsewhereAsync(string path)
    {
        if (options.SmokeSession is not { } file || !File.Exists(file))
        {
            Log("session from elsewhere: not checked");
            return;
        }
        var window = App.Current.OpenFile(file);
        await Task.Delay(2500);
        Log($"opened {Path.GetFileName(file)}: {window.Describe()}");
        await window.ShowSessionRowsAsync(this, path);
        window.Close();
    }

    /// <summary>
    /// The self-check for Reqly opened to show a file, as File Explorer opens one: only the file's
    /// window shows. Opening Reqly again with another file opens it here, and that launch quits;
    /// opening it again without one shows the live window; its close button, while a file is open,
    /// hides it and stops capturing. Closing the last file's window then quits Reqly, which the
    /// test run sees.
    /// </summary>
    public async Task CheckOpeningFilesAsync(string path)
    {
        try
        {
            await Task.Delay(4000);
            var files = App.Current.FileWindows;
            Log($"opened with {options.FilesToOpen.Count} file(s): {files.Count(window => window.IsShowing)} file window(s) showing, live window {(IsShowing ? "showing" : "hidden")}");
            foreach (var window in files)
            {
                Log($"  {window.Describe()}");
            }
            if (files.FirstOrDefault() is { } first)
            {
                await first.SaveScreenshotAsync(path + ".opened-file.png");
            }
            if (options.SmokeSession is { } another && File.Exists(another))
            {
                var watch = Stopwatch.StartNew();
                using var later = LaunchAgain(another);
                var full = Path.GetFullPath(another);
                var opened = await WaitForAsync(() => App.Current.FileWindows.Any(window => string.Equals(window.FilePath, full, StringComparison.OrdinalIgnoreCase)));
                var openedAfter = watch.ElapsedMilliseconds;
                var quit = later is not null && await WaitForAsync(() => later.HasExited);
                Log($"opened again with {Path.GetFileName(another)}: {(opened ? $"its window opened here after {openedAfter} ms" : "no window opened here")}, " +
                    $"and that launch {(quit ? $"quit with {later!.ExitCode}" : "didn't quit")}; live window {(IsShowing ? "showing" : "hidden")}");
            }
            using (var again = LaunchAgain(null))
            {
                var shown = await WaitForAsync(() => IsShowing);
                var quit = again is not null && await WaitForAsync(() => again.HasExited);
                await Task.Delay(3000);
                var front = GetForegroundWindow() == WinRT.Interop.WindowNative.GetWindowHandle(this);
                Log($"opened again without files: the live window {(shown ? "shows" : "stays hidden")}{(front ? ", in front" : "")}, " +
                    $"and that launch {(quit ? $"quit with {again!.ExitCode}" : "didn't quit")}; {Describe()}");
                await SaveScreenshotAsync(path + ".live-opened-again.png");
            }
            // Its close button sends this.
            PostMessage(WinRT.Interop.WindowNative.GetWindowHandle(this), 0x0010, 0, 0);
            var hidden = await WaitForAsync(() => !IsShowing);
            // Without Reqly's icon in the notification area, it stops capturing.
            if (!App.Current.ShowsNotificationIcon)
            {
                await WaitForAsync(() => capture == Capture.Stopped);
            }
            Log($"closed the live window with a file open: it {(hidden ? "hid" : "still shows")}, capture {capture}, " +
                $"its session {(session is null ? "is gone" : "stays")}, {App.Current.FileWindows.Count} file window(s) open");
        }
        catch (Exception error)
        {
            Log($"error: {error}");
        }
        File.WriteAllText(path, report.ToString());
        // The last file's window closing quits Reqly, unless Reqly goes on in the notification
        // area, as it does once you've opened Reqly itself.
        foreach (var window in App.Current.FileWindows.ToList())
        {
            window.Close();
        }
        await Task.Delay(1500);
        Log($"closed the files' windows: Reqly goes on{(App.Current.ShowsNotificationIcon ? " in the notification area" : "")}");
        File.WriteAllText(path, report.ToString());
        App.Current.Quit();
    }

    /// <summary>Starts Reqly again, with this run's options and another file, or none, as File Explorer would.</summary>
    private Process? LaunchAgain(string? openedFile)
    {
        var arguments = Environment.GetCommandLineArgs().Skip(1).Where(argument => !options.FilesToOpen.Contains(argument)).ToList();
        if (openedFile is not null)
        {
            arguments.Add(openedFile);
        }
        // Through the shell, so it gets none of this Reqly's handles.
        return Process.Start(new ProcessStartInfo(Environment.ProcessPath!)
        {
            UseShellExecute = true,
            Arguments = string.Join(" ", arguments.Select(argument => argument.Contains(' ') ? $"\"{argument}\"" : argument)),
        });
    }

    private static async Task<bool> WaitForAsync(Func<bool> condition, int seconds = 15)
    {
        for (var waited = 0; waited < seconds * 1000; waited += 200)
        {
            if (condition())
            {
                return true;
            }
            await Task.Delay(200);
        }
        return condition();
    }

    [LibraryImport("user32.dll", EntryPoint = "PostMessageW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool PostMessage(IntPtr window, uint message, nint wParam, nint lParam);

    [LibraryImport("user32.dll")]
    private static partial IntPtr GetForegroundWindow();

    /// <summary>Shows some of this window's requests, each on the tab that shows it best, for `checker`'s report.</summary>
    private async Task ShowSessionRowsAsync(MainWindow checker, string path)
    {
        var picks = new (string Find, string Tab, string Name)[]
        {
            ("/v2/forecast?city=Lisbon", "overview", "mac-app"),
            // Its Authorization header is a secret, hidden behind Show.
            ("/v2/forecast?city=Lisbon", "request", "secret"),
            ("/v2/search", "response", "persian"),
            ("/v2/greeting", "response", "gzip"),
            ("/icons/sun.png", "response", "image"),
            ("/socket", "messages", "websocket"),
            ("city=Oslo", "overview", "emulator"),
            ("maps.weatherly.dev", "overview", "tunnel"),
        };
        foreach (var (find, tab, name) in picks)
        {
            if (list?.Rows.FirstOrDefault(row => (row.DisplayHost + row.Rest).Contains(find)) is not { } row)
            {
                checker.Log($"{name}: the row didn't show");
                continue;
            }
            List.SelectedItem = row;
            await Task.Delay(800);
            Inspector.ShowTab(tab);
            await Task.Delay(1200);
            checker.Log($"{name}: app {row.App} · {Inspector.Describe()} · {Inspector.ContentText(360).ReplaceLineEndings(" ")}");
            await SaveScreenshotAsync(Root, $"{path}.elsewhere-{name}.png");
        }
    }

    /// <summary>Pictures the first-run guide, which test runs otherwise leave closed.</summary>
    private async Task CheckWelcomeAsync(string path)
    {
        ShowWelcome();
        await Task.Delay(1500);
        if (welcomeWindow is { } window)
        {
            Log($"welcome: {window.Describe()}");
            await SaveScreenshotAsync(window.View, path + ".welcome.png");
            window.Close();
        }
        else
        {
            Log("welcome: didn't show");
        }
    }

    private async Task SaveSettingsPictureAsync(string path, SettingsWindow.Pane pane)
    {
        ShowSettings(pane);
        await Task.Delay(1500);
        if (settingsWindow is { } window)
        {
            await SaveScreenshotAsync(window.View, path);
            window.Close();
        }
    }

    /// <summary>
    /// Sends a request for each kind of status, then narrows the list from the sidebar and with
    /// the filters, pins, marks and comments on a request, reads its menu, copies it, and clears.
    /// </summary>
    private async Task CheckListAsync(string path, int port, X509Certificate2[] trusted)
    {
        using (var client = Client(port, trusted))
        {
            foreach (var page in new[] { "missing", "broken", "moved" })
            {
                using var response = await client.GetAsync($"https://localhost:{testServer!.Port}/v1/{page}");
                Log($"{page}: {(int)response.StatusCode}");
            }
        }
        await Task.Delay(1500);
        if (sidebar?.Latest is { } latest)
        {
            Log($"sidebar: total {sidebar.Total}, apps {string.Join(", ", latest.Apps.Select(app => $"{app.Name} {sidebar.CountOf(app.Key)}"))}, hosts {string.Join(", ", latest.Hosts.Select(host => $"{host.Name} {sidebar.CountOf(host.Key)}"))}, methods {string.Join(" ", latest.Methods)}");
            if (latest.Hosts.FirstOrDefault(host => host.Name == "localhost") is { } localhost)
            {
                sidebar.Select(localhost.Key);
                await Task.Delay(1000);
                Log($"localhost only: {Heading.Text} · {Subheading.Text} · {list?.Rows.Count} rows");
            }
            sidebar.Select("all");
            await Task.Delay(800);
            Log($"all traffic: {Heading.Text} · {Subheading.Text}");
        }
        await Filters.SetStatusesAsync(["clientError", "serverError"]);
        await Task.Delay(800);
        Log($"4xx and 5xx: {list?.Rows.Count} rows · {string.Join(", ", list?.Rows.Select(row => row.Status) ?? [])}");
        await Filters.SetStatusesAsync(["redirection"]);
        await Task.Delay(800);
        Log($"3xx: {list?.Rows.Count} rows");
        await Filters.ClearAsync();
        await Task.Delay(800);
        Log($"no filters: {list?.Rows.Count} rows");

        if (list?.Rows.FirstOrDefault(row => row.Status == "404") is { } missing)
        {
            await AnnotateAsync(missing, new JsonObject { ["isPinned"] = true, ["color"] = "red", ["comment"] = "  Shows up on 3G  " });
            await Task.Delay(800);
            Log($"marked: pinned {missing.IsPinned}, color {missing.Color}, comment “{missing.Comment}”, reads as “{missing}”");
            var menu = await MenuAsync(missing);
            Log($"menu: {string.Join(" | ", menu.Items.Select(MenuText))}");
            await CopyUrlAsync(missing);
            Log($"copied URL: {lastCopied}");
            await CopyCurlAsync(missing);
            Log($"copied cURL: {lastCopied?.ReplaceLineEndings(" ")}");
            List.SelectedItem = missing;
            await Task.Delay(1200);
            await SaveScreenshotAsync(Root, path + ".list.png");
            // A wider App column, which the title and every row follow.
            Traffic.ListColumns.Shared.Set(2, 180);
            await Task.Delay(600);
            Log($"App column: {Traffic.ListColumns.Shared[2]} wide");
            await SaveScreenshotAsync(Root, path + ".columns.png");
            Traffic.ListColumns.Shared.Set(2, Traffic.ListColumns.Columns[2].Width);
        }
        if (list?.Rows.FirstOrDefault(row => row.Status == "500") is { } broken)
        {
            await AnnotateAsync(broken, new JsonObject { ["color"] = "blue" });
        }
        await Filters.SetStatusesAsync(["failed"]);
        await Task.Delay(800);
        await Filters.ClearAsync();
        SearchBox.Text = "no-request-has-this";
        await Task.Delay(800);
        Log($"no matches: {NoMatchesTitle.Text} · {NoMatchesText.Text}");
        await SaveScreenshotAsync(Root, path + ".nomatches.png");
        SearchBox.Text = "";
        await Task.Delay(500);

        await CheckFilesAsync(path);
        await CheckComposerAsync(path);
        await CheckBreakpointAsync(path);
        await CheckRuleKindsAsync(path, port, trusted);
        await CheckProtobufAsync(path, port, trusted);
        await CheckBrotliAsync(path, port, trusted);
        await CheckClearingWhileHeldAsync(port);
        await Task.Delay(1200);
        Log($"after clearing: {list?.Rows.Count} of {list?.Total} · {Subheading.Text} · selected {SelectedRow?.Status}");
    }

    /// <summary>
    /// Holds an app's request at a breakpoint, then clears the traffic, as the trash button does. The
    /// request should go on as it came, rather than wait for a decision no one can make anymore.
    /// </summary>
    private async Task CheckClearingWhileHeldAsync(int port)
    {
        if (rules is null)
        {
            Log("cleared while held: not checked");
            return;
        }
        var draft = await rules.NewDraftAsync("breakpoint");
        draft.Name = "Hold while clearing";
        draft.Host = "weather.invalid";
        draft.Phase = "request";
        await rules.SaveAsync(draft);
        await rules.SetOnAsync("breakpoint", true);
        using var client = Client(port);
        var watch = Stopwatch.StartNew();
        // .invalid never resolves, so once it goes on, Reqly answers it itself.
        var fetching = client.GetAsync("http://weather.invalid/v2/cleared");
        await Task.Delay(2000);
        var heldBefore = paused.Count;
        await ClearAsync();
        string outcome;
        if (await Task.WhenAny(fetching, Task.Delay(8000)) == fetching)
        {
            try
            {
                using var response = await fetching;
                outcome = $"went on: {(int)response.StatusCode} after {watch.Elapsed.TotalSeconds:F1} s";
            }
            catch (HttpRequestException error)
            {
                outcome = $"went on and failed: {error.HttpRequestError}";
            }
        }
        else
        {
            outcome = "was still held 8 s after clearing";
        }
        Log($"cleared while held: {heldBefore} held before, {paused.Count} after · the request {outcome} · editor {PausedArea.Visibility}");
        await rules.SetOnAsync("breakpoint", false);
        foreach (var rule in rules.Rules.Rules)
        {
            await rules.RemoveAsync(rule.Id);
        }
    }

    /// <summary>Saves the session and exports it as HAR, then opens both, each in a window of its own.</summary>
    private async Task CheckFilesAsync(string path)
    {
        var saved = path + ".reqly";
        var har = path + ".har";
        await SaveSessionAsync(saved, hidesSecrets: true);
        var exported = await ExportHarAsync(har, null, includesBodies: true, hidesSecrets: true);
        Log($"saved {new FileInfo(saved).Length:N0} bytes; exported {exported} requests to HAR, {new FileInfo(har).Length:N0} bytes");
        foreach (var opened in new[] { saved, har })
        {
            var window = App.Current.OpenFile(opened);
            await Task.Delay(2500);
            Log($"opened {Path.GetFileName(opened)}: {window.Describe()}");
            if (opened == saved)
            {
                await window.SaveScreenshotAsync(path + ".file.png");
            }
            window.Close();
        }
    }

    /// <summary>Writes and sends requests, then resends one from the list and edits another.</summary>
    private async Task CheckComposerAsync(string path)
    {
        var composer = ShowComposer(null);
        if (composer is null)
        {
            Log("composer: didn't open");
            return;
        }
        composer.UseAddress("ftp://weather.invalid/");
        await composer.SendAsync();
        Log($"composer with an ftp URL: {composer.Describe()}");
        // .invalid never resolves, so nothing leaves the computer.
        composer.UseAddress("weather.invalid/v2/compose?day=today");
        await composer.SendAsync();
        await Task.Delay(1000);
        Log($"composer sent: {composer.Describe()}");
        await SaveScreenshotAsync(composer.Content, path + ".composer.png");
        composer.Close();
        if (list?.Rows.FirstOrDefault(row => row.Status == "500") is { } broken)
        {
            var before = list.Total;
            await ResendAsync(broken);
            await Task.Delay(1500);
            Log($"resent the 500: {before} → {list.Total} requests · selected {SelectedRow?.Status} {SelectedRow?.Rest}");
            await EditAndResendAsync(broken);
            await Task.Delay(800);
        }
    }

    /// <summary>
    /// Makes a breakpoint in the Rules window's editor, holds a request at it, edits the request in
    /// the paused editor and lets it go on; then writes a script and tries it on that request, and
    /// shows Slow Network. The rules go again after, and the rules file is the test run's own.
    /// </summary>
    private async Task CheckBreakpointAsync(string path)
    {
        if (session is null || rules is null || ShowRules("breakpoint") is not { } window)
        {
            Log("rules: not checked");
            return;
        }
        await Task.Delay(1500);
        var draft = await rules.NewDraftAsync("breakpoint");
        draft.Name = "Hold the weather";
        draft.Host = "weather.invalid";
        draft.Phase = "request";
        var editing = window.EditAsync(draft);
        await Task.Delay(1500);
        if (window.Editor is RuleEditorDialog editor)
        {
            Log($"rule editor: {editor.Describe()}");
            await SaveScreenshotAsync(editor, path + ".rule-editor.png");
            Log($"saving the breakpoint: {await rules.SaveAsync(draft) ?? "saved"}");
            editor.Hide();
        }
        else
        {
            Log("rule editor: didn't show");
        }
        await editing;
        await Task.Delay(800);
        Log($"rules window: {window.Describe()} · toolbar breakpoints {BreakpointsButton.IsChecked}");
        await SaveScreenshotAsync(window.View, path + ".rules.png");

        // .invalid never resolves, so nothing leaves the computer.
        await SendAsync(new WireOutgoing { Method = "GET", Url = "https://weather.invalid/v2/held" });
        await Task.Delay(1500);
        if (PausedArea.Content is Reqly.Inspector.PausedEditor paused)
        {
            Log($"paused: {paused.Describe()}");
            await SaveScreenshotAsync(Root, path + ".paused.png");
            await paused.ContinueWithUrlAsync("ftp://weather.invalid/");
            Log($"paused, with an ftp URL: {paused.Describe()}");
            await paused.ContinueWithUrlAsync("https://weather.invalid/v2/edited");
            await Task.Delay(1500);
            Log($"after continuing: editor shows {PausedArea.Visibility}, {this.paused.Count} held · {Inspector.Describe()}");
        }
        else
        {
            Log("paused: no editor showed");
        }
        await rules.SetOnAsync("breakpoint", false);

        var script = await rules.NewDraftAsync("script");
        script.Host = "weather.invalid";
        script.Code = rules.Examples.FirstOrDefault(example => example.Id == "log")?.Code ?? script.Code;
        var scripting = window.EditAsync(script);
        await Task.Delay(2000);
        if (window.Editor is ScriptEditorDialog scriptEditor)
        {
            await scriptEditor.TryItAsync();
            await Task.Delay(800);
            Log($"script editor: {scriptEditor.Describe()}");
            Log($"script editing: {await scriptEditor.CheckEditingAsync()}");
            await SaveScreenshotAsync(scriptEditor, path + ".script-editor.png");
            scriptEditor.Hide();
        }
        else
        {
            Log("script editor: didn't show");
        }
        await scripting;
        window.Show("slowNetwork");
        await Task.Delay(1000);
        Log($"slow network: {window.Describe()}");
        await SaveScreenshotAsync(window.View, path + ".slow-network.png");
        foreach (var rule in rules.Rules.Rules)
        {
            await rules.RemoveAsync(rule.Id);
        }
        window.Close();
        Log($"rules after: {rules.Rules.Rules.Length}, on: {string.Join(", ", rules.Rules.KindsOn)}");
    }

    /// <summary>What this window shows, for the self-check of a file's window.</summary>
    public string Describe() => $"{AppTitleBar.Subtitle} · {Heading.Text} · {Subheading.Text} · {list?.Rows.Count} rows · status “{StatusText.Text}” · capture button {CaptureButton.Visibility}";

    public Task SaveScreenshotAsync(string path) => SaveScreenshotAsync(Root, path);

    private static string MenuText(MenuFlyoutItemBase item) => item switch
    {
        MenuFlyoutSeparator => "—",
        MenuFlyoutSubItem sub => $"{sub.Text} ▸ {string.Join(", ", sub.Items.OfType<MenuFlyoutItem>().Select(child => (child as ToggleMenuFlyoutItem)?.IsChecked == true ? child.Text + " ✓" : child.Text))}",
        MenuFlyoutItem entry => entry.IsEnabled ? entry.Text : $"({entry.Text})",
        _ => "?",
    };

    private string Hosts() =>
        string.Join(", ", https?.Hosts.Entries.Select(entry => $"{entry.Pattern} {(entry.IsOn ? "on" : "off")}") ?? []);

    /// <summary>
    /// A client that sends everything through Reqly. For HTTPS, it trusts only the certificates
    /// given, and tells <paramref name="seen"/> who issued the server's.
    /// </summary>
    private static HttpClient Client(int port, X509Certificate2[]? trusted = null, Action<string>? seen = null)
    {
        var handler = new HttpClientHandler { Proxy = new WebProxy($"http://127.0.0.1:{port}"), UseProxy = true };
        if (trusted is not null)
        {
            handler.ServerCertificateCustomValidationCallback = (_, certificate, _, errors) =>
            {
                if (certificate is null)
                {
                    return false;
                }
                seen?.Invoke(certificate.Issuer);
                using var chain = new X509Chain();
                chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
                chain.ChainPolicy.CustomTrustStore.AddRange(trusted);
                chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
                // Only the chain is checked here; the name must match as usual.
                return chain.Build(certificate) && (errors & ~SslPolicyErrors.RemoteCertificateChainErrors) == 0;
            };
        }
        return new HttpClient(handler, disposeHandler: true) { Timeout = TimeSpan.FromSeconds(15) };
    }

    private async Task SaveScreenshotAsync(UIElement element, string path) => Log(await Smoke.Pictures.SaveAsync(element, path));
}
