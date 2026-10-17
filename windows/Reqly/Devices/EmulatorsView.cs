using System.Text.Json.Nodes;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Reqly.Core;
using Reqly.Inspector;

namespace Reqly.Devices;

/// <summary>
/// Android emulators, as the Mac's pane: each one running, pointed at Reqly with adb, and given
/// Reqly's certificate. The emulator reaches this PC at 10.0.2.2, so Reqly needn't listen on the network.
/// </summary>
public sealed partial class EmulatorsView : UserControl
{
    private readonly MainWindow main;
    private readonly StackPanel content = new() { Spacing = 4 };
    private WireEmulators shown = new(true, [], null);
    /// <summary>The emulators being changed right now.</summary>
    private readonly HashSet<string> busy = [];
    /// <summary>What happened last with each emulator, such as a failure.</summary>
    private readonly Dictionary<string, string> notes = [];
    private bool isRefreshing;
    private DispatcherQueueTimer? refresher;
    /// <summary>What the page showed last, so it's laid out again only when that changes.</summary>
    private string? shownState;

    public EmulatorsView(MainWindow main)
    {
        this.main = main;
        Content = content;
        Loaded += (_, _) =>
        {
            main.CaptureChanged += Show;
            refresher = DispatcherQueue.CreateTimer();
            refresher.Interval = TimeSpan.FromSeconds(10);
            refresher.Tick += CrashReports.Reported.Tick(() => _ = RefreshAsync());
            refresher.Start();
            Show();
            _ = RefreshAsync();
        };
        Unloaded += (_, _) =>
        {
            main.CaptureChanged -= Show;
            refresher?.Stop();
        };
    }

    /// <summary>The port emulators use: the one Reqly listens on, or the one in Settings.</summary>
    private int Port => main.CapturingPort ?? main.Port;

    /// <summary>What the page shows, for the self-check.</summary>
    public string Describe() => shown.Problem ?? $"{shown.Emulators.Length} running";

    private async Task RefreshAsync()
    {
        if (main.LiveSession is not { } session || isRefreshing)
        {
            return;
        }
        isRefreshing = true;
        Show();
        try
        {
            shown = Wire.Read<WireEmulators>(await session.CallAsync(new JsonObject { ["call"] = "emulators", ["port"] = Port }));
        }
        catch (CoreProblem problem)
        {
            AppLog.Write($"couldn't list the emulators: {problem.Message}");
        }
        isRefreshing = false;
        Show();
    }

    private void Show()
    {
        var state = string.Join(
            "|", main.CapturingPort is null, main.IsCaptureBusy, isRefreshing, shown.HasAdb, shown.Problem, main.TrustedCertificate is null,
            string.Join(",", shown.Emulators.Select(emulator => $"{emulator.Id}={emulator.Name}:{emulator.Proxy}:{emulator.IsReady}:{emulator.UsesReqly}")),
            string.Join(",", busy), string.Join(",", notes.Select(note => $"{note.Key}={note.Value}")));
        if (state == shownState)
        {
            return;
        }
        shownState = state;
        content.Children.Clear();
        content.Children.Add(Blocks.Note("Android emulators send their traffic through Reqly once their proxy points at this PC. Reqly sets that up with adb."));
        if (main.CapturingPort is null)
        {
            var start = new Button { Content = "Start capturing", IsEnabled = !main.IsCaptureBusy };
            start.Click += async (_, _) => await main.StartCapturingFromDevicesAsync();
            content.Children.Add(Card(Line("Start capturing, so emulators can connect.", null, start)));
        }
        if (shown.Problem is { } problem)
        {
            content.Children.Add(Blocks.Failure(problem));
        }

        content.Children.Add(Header("Running emulators"));
        var rows = new StackPanel { Spacing = 14 };
        if (shown.HasAdb && shown.Problem is null && shown.Emulators.Length == 0)
        {
            rows.Children.Add(Blocks.Note("No emulators are running. Start one from Android Studio's Device Manager."));
        }
        foreach (var emulator in shown.Emulators)
        {
            rows.Children.Add(Row(emulator));
        }
        var refresh = new Button { Content = "Refresh", IsEnabled = shown.HasAdb && !isRefreshing, HorizontalAlignment = HorizontalAlignment.Right };
        refresh.Click += async (_, _) => await RefreshAsync();
        rows.Children.Add(refresh);
        content.Children.Add(Card(rows));

        content.Children.Add(Header("HTTPS"));
        var https = new StackPanel { Spacing = 8 };
        https.Children.Add(new TextBlock
        {
            Text = "Copy certificate puts Reqly's certificate in the emulator's Downloads and opens its security settings. There, choose Encryption & credentials › Install a certificate › CA certificate, then pick Reqly CA. On recent versions of Android, Encryption & credentials is under More security & privacy.",
            TextWrapping = TextWrapping.Wrap,
        });
        https.Children.Add(Blocks.Note("On Android 7 and later, apps trust it only if they opt in. Debug builds of your own apps can."));
        content.Children.Add(Card(https));
    }

    /// <summary>An emulator: its name, whether it uses Reqly, and the buttons that change that and copy the certificate.</summary>
    private UIElement Row(WireEmulator emulator)
    {
        var status = !emulator.IsReady ? "Starting up"
            : emulator.UsesReqly ? "Sends its traffic through Reqly"
            : emulator.Proxy is { } other ? $"Uses another proxy, {other}"
            : "Doesn't use Reqly";
        var isBusy = busy.Contains(emulator.Id);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (isBusy)
        {
            buttons.Children.Add(new ProgressRing { Width = 16, Height = 16, IsActive = true, VerticalAlignment = VerticalAlignment.Center });
        }
        var use = new Button { Content = emulator.UsesReqly ? "Stop using Reqly" : "Use Reqly", IsEnabled = emulator.IsReady && !isBusy };
        use.Click += async (_, _) => await ChangeAsync(emulator, new JsonObject
        {
            ["call"] = "setEmulatorUsesReqly",
            ["serial"] = emulator.Id,
            ["isOn"] = !emulator.UsesReqly,
            ["port"] = Port,
        });
        var certificate = main.TrustedCertificate;
        var copy = new Button { Content = "Copy certificate", IsEnabled = emulator.IsReady && !isBusy && certificate is not null };
        if (certificate is null)
        {
            ToolTipService.SetToolTip(copy, "Set up HTTPS first, with Capture › Decrypt HTTPS.");
        }
        copy.Click += async (_, _) =>
        {
            if (main.TrustedCertificate is { } der)
            {
                await ChangeAsync(emulator, new JsonObject
                {
                    ["call"] = "copyCertificateToEmulator",
                    ["serial"] = emulator.Id,
                    ["certificate"] = Convert.ToBase64String(der),
                });
            }
        };
        buttons.Children.Add(use);
        buttons.Children.Add(copy);
        var row = new StackPanel { Spacing = 4 };
        row.Children.Add(Line(emulator.Name, status, buttons));
        if (notes.TryGetValue(emulator.Id, out var note))
        {
            row.Children.Add(Blocks.Note(note));
        }
        return row;
    }

    /// <summary>Runs an adb change on an emulator, keeps what came of it, and reads the emulators again.</summary>
    private async Task ChangeAsync(WireEmulator emulator, JsonObject call)
    {
        if (main.LiveSession is not { } session)
        {
            return;
        }
        busy.Add(emulator.Id);
        notes.Remove(emulator.Id);
        Show();
        try
        {
            var result = Wire.Read<WireCheck>(await session.CallAsync(call));
            if ((result.Problem ?? result.Note) is { } note)
            {
                notes[emulator.Id] = note;
            }
        }
        catch (CoreProblem problem)
        {
            notes[emulator.Id] = problem.Message;
        }
        busy.Remove(emulator.Id);
        await RefreshAsync();
    }

    private static Border Card(UIElement child) => new()
    {
        Style = (Style)Application.Current.Resources["SettingsCardStyle"],
        Child = child,
        Margin = new Thickness(0, 0, 0, 4),
    };

    private static TextBlock Header(string text) => new()
    {
        Text = text,
        Style = (Style)Application.Current.Resources["SettingsSectionHeaderStyle"],
    };

    private static Grid Line(string title, string? details, UIElement? control)
    {
        var line = new Grid { ColumnSpacing = 16 };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap });
        if (details is not null)
        {
            words.Children.Add(new TextBlock { Text = details, Style = (Style)Application.Current.Resources["SettingsDescriptionStyle"] });
        }
        line.Children.Add(words);
        if (control is FrameworkElement element)
        {
            Grid.SetColumn(element, 1);
            element.VerticalAlignment = VerticalAlignment.Center;
            line.Children.Add(element);
        }
        return line;
    }
}
