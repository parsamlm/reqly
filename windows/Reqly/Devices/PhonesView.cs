using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Reqly.Inspector;

namespace Reqly.Devices;

/// <summary>
/// Phones and tablets, as the Mac's pane: whether devices on the network may connect, the ones
/// waiting for you, how to set one up, its proxy settings, and the devices you let in.
/// </summary>
public sealed partial class PhonesView : UserControl
{
    private readonly MainWindow main;
    private readonly DevicesModel devices;
    private readonly StackPanel content = new() { Spacing = 4 };
    private readonly ToggleSwitch allows = new() { MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
    /// <summary>The switch's card, made once and put back each time the page is laid out, so the switch keeps its focus.</summary>
    private readonly Border allowsCard;
    private DispatcherQueueTimer? refresher;
    /// <summary>The address the QR code shows, and its card, made again only when the address changes.</summary>
    private string? shownAddress;
    private Border? codeCard;
    /// <summary>What the page showed last, so it's laid out again only when that changes.</summary>
    private string? shownState;
    private bool isShowing;
    /// <summary>The kinds of network on which Windows Firewall blocks Reqly, as its rules last said.</summary>
    private string[] blockedOn = [];

    public PhonesView(MainWindow main, DevicesModel devices, Func<IntPtr> window)
    {
        this.main = main;
        this.devices = devices;
        Content = content;
        AutomationProperties.SetName(allows, "Allow devices on this network");
        allowsCard = Card(Line(
            "Allow devices on this network",
            "Phones and tablets on the same Wi-Fi as this PC can send their traffic through Reqly. Reqly asks before it lets a new device in.",
            allows));
        allows.Toggled += async (_, _) =>
        {
            if (!isShowing && allows.IsOn != devices.Devices.AllowsNetworkDevices)
            {
                await main.SetAllowsNetworkDevicesAsync(allows.IsOn);
            }
        };
        Loaded += (_, _) =>
        {
            devices.Changed += Show;
            main.CaptureChanged += Show;
            // This PC's addresses change as it joins and leaves networks.
            refresher = DispatcherQueue.CreateTimer();
            refresher.Interval = TimeSpan.FromSeconds(5);
            refresher.Tick += CrashReports.Reported.Tick(() =>
            {
                _ = devices.RefreshAsync();
                _ = CheckFirewallAsync();
            });
            refresher.Start();
            _ = devices.RefreshAsync();
            _ = CheckFirewallAsync();
            Show();
        };
        Unloaded += (_, _) =>
        {
            devices.Changed -= Show;
            main.CaptureChanged -= Show;
            refresher?.Stop();
        };
    }

    /// <summary>The port devices use: the one Reqly listens on, or the one in Settings.</summary>
    private int Port => main.CapturingPort ?? main.Port;

    private string? Url => devices.Devices.Addresses.FirstOrDefault() is { } first ? $"http://{first.Address}:{Port}/" : null;

    /// <summary>What the page shows, for the self-check.</summary>
    public string Describe() =>
        $"{(devices.Devices.AllowsNetworkDevices ? "allowed" : "not allowed")} · {devices.Devices.Known.Length} let in · {devices.Devices.Waiting.Length} waiting · {Url ?? "no address"}";

    /// <summary>Lays the page out again when what it shows changed. The addresses are read every few seconds.</summary>
    private void Show()
    {
        var shown = devices.Devices;
        var state = string.Join(
            "|", shown.AllowsNetworkDevices, shown.Problem, Port, main.CapturingPort is null, main.IsCaptureBusy,
            main.TrustedCertificateName, string.Join(",", shown.Waiting.Select(device => device.Id)),
            string.Join(",", shown.Known.Select(device => $"{device.Id}={device.Name}@{device.Address}")),
            string.Join(",", shown.Addresses.Select(address => $"{address.Interface}={address.Address}")),
            string.Join(",", blockedOn));
        if (state == shownState)
        {
            return;
        }
        shownState = state;
        try
        {
            ShowContents();
        }
        catch (Exception error)
        {
            AppLog.Write($"the phones page couldn't show: {error.Message}");
        }
        finally
        {
            isShowing = false;
        }
    }

    private void ShowContents()
    {
        isShowing = true;
        var shown = devices.Devices;
        content.Children.Clear();
        if (shown.Problem is { } problem)
        {
            var failure = Blocks.Failure(problem);
            failure.Margin = new Thickness(0, 0, 0, 12);
            content.Children.Add(failure);
        }
        allows.IsOn = shown.AllowsNetworkDevices;
        content.Children.Add(allowsCard);
        if (shown.AllowsNetworkDevices && blockedOn.Length > 0)
        {
            var open = new Button { Content = "Open firewall settings" };
            open.Click += (_, _) => Firewall.OpenSettings();
            content.Children.Add(Card(Line(
                $"Windows Firewall is blocking Reqly on {string.Join(" and ", blockedOn)} networks",
                "So devices can't connect. In the firewall's list of allowed apps, allow Reqly for private networks, such as your home Wi-Fi.",
                open,
                "\uE7BA")));
        }

        if (shown.Waiting.Length > 0)
        {
            content.Children.Add(Header("Waiting for you"));
            var rows = new StackPanel { Spacing = 12 };
            foreach (var device in shown.Waiting)
            {
                var refuse = new Button { Content = "Don't allow" };
                refuse.Click += async (_, _) => await devices.DecideAsync(device.Id, allow: false);
                var allow = new Button { Content = "Allow", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
                allow.Click += async (_, _) => await devices.DecideAsync(device.Id, allow: true);
                var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                buttons.Children.Add(refuse);
                buttons.Children.Add(allow);
                rows.Children.Add(Line($"A device at {device.Address}", null, buttons, ""));
            }
            content.Children.Add(Card(rows));
        }

        if (shown.AllowsNetworkDevices)
        {
            if (Url is { } url)
            {
                content.Children.Add(Header("Set up a device"));
                if (url != shownAddress || codeCard is null)
                {
                    shownAddress = url;
                    codeCard = Card(SetupCode(url));
                }
                content.Children.Add(codeCard);
                content.Children.Add(Card(CaptureLine()));
                content.Children.Add(Card(CertificateLine()));
                content.Children.Add(Header("Proxy settings"));
                var settings = new StackPanel();
                settings.Children.Add(Blocks.Row("Server", shown.Addresses[0].Address, monospaced: true));
                settings.Children.Add(Blocks.Row("Port", Port.ToString(System.Globalization.CultureInfo.InvariantCulture), monospaced: true));
                foreach (var other in shown.Addresses.Skip(1))
                {
                    settings.Children.Add(Blocks.Row($"On {other.Interface}", other.Address, monospaced: true));
                }
                content.Children.Add(Card(settings));
                content.Children.Add(Footer("On the device, enter these in the Wi-Fi network's proxy settings, under Manual. Set the proxy back to Off when you're done."));
            }
            else
            {
                content.Children.Add(Card(Line("This PC isn't on a network that devices can reach.", null, null, "")));
            }
        }

        content.Children.Add(Header("Devices you let in"));
        var known = new StackPanel { Spacing = 12 };
        if (shown.Known.Length == 0)
        {
            known.Children.Add(Blocks.Note("The devices you let in show up here."));
        }
        foreach (var device in shown.Known)
        {
            var forget = new Button { Content = "Forget" };
            ToolTipService.SetToolTip(forget, "Reqly asks again the next time this device connects.");
            forget.Click += async (_, _) => await devices.ForgetAsync(device.Id);
            var details = device.HardwareAddress is { } hardware ? $"{device.Address} · {hardware}" : device.Address;
            known.Children.Add(Line(device.Name ?? device.Address, details, forget, ""));
        }
        content.Children.Add(Card(known));
        content.Children.Add(Footer("The first time devices connect, Windows may ask whether Reqly can accept connections from your network. Choose Allow, or they can't connect."));
        isShowing = false;
    }

    /// <summary>Asks Windows Firewall's rules whether they block Reqly, while devices may connect.</summary>
    private async Task CheckFirewallAsync()
    {
        if (!devices.Devices.AllowsNetworkDevices)
        {
            return;
        }
        var found = await Firewall.BlockedOnAsync();
        if (!found.SequenceEqual(blockedOn))
        {
            blockedOn = found;
            AppLog.Write(found.Length == 0 ? "Windows Firewall lets Reqly in" : $"Windows Firewall blocks Reqly on {string.Join(", ", found)} networks");
            Show();
        }
    }

    /// <summary>The setup page's address, as a QR code for the device's camera and as text.</summary>
    private Grid SetupCode(string url)
    {
        var grid = new Grid { ColumnSpacing = 20 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var code = new Image { Width = 132, Height = 132, Stretch = Stretch.None };
        AutomationProperties.SetName(code, $"QR code for {url}");
        _ = DrawCodeAsync(code, url);
        // A code is dark on white, whichever mode Windows is in.
        var frame = new Border
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.White),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(8),
            VerticalAlignment = VerticalAlignment.Top,
        };
        frame.Child = code;
        grid.Children.Add(frame);
        var words = new StackPanel { Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock { Text = "On the device, scan the code with the camera, or open this address in its browser:", TextWrapping = TextWrapping.Wrap });
        var address = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        address.Children.Add(new TextBlock { Text = url, FontFamily = Blocks.Mono, FontSize = 18, IsTextSelectionEnabled = true, VerticalAlignment = VerticalAlignment.Center });
        address.Children.Add(Blocks.IconButton("", "Copy address", () => main.CopyAddress(url)));
        words.Children.Add(address);
        words.Children.Add(Blocks.Note("The page there has Reqly's certificate, and the steps for iPhone, iPad and Android."));
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        return grid;
    }

    /// <summary>The setup code alone, for the self-check's picture of it, without letting devices connect.</summary>
    public static UIElement CodePreview(MainWindow main, DevicesModel devices, string url)
    {
        var view = new PhonesView(main, devices, () => IntPtr.Zero);
        return Card(view.SetupCode(url));
    }

    /// <summary>Draws the code at 4 pixels a module, with the quiet zone scanners need around it.</summary>
    private async Task DrawCodeAsync(Image image, string url)
    {
        if (await devices.QRCodeAsync(url) is not { } rows)
        {
            return;
        }
        const int scale = 4;
        var modules = rows.Length;
        var side = (modules + 8) * scale;
        var pixels = new byte[side * side * 4];
        Array.Fill(pixels, (byte)255);
        for (var y = 0; y < modules; y++)
        {
            for (var x = 0; x < modules; x++)
            {
                if (!rows[y][x])
                {
                    continue;
                }
                for (var dy = 0; dy < scale; dy++)
                {
                    for (var dx = 0; dx < scale; dx++)
                    {
                        var at = (((y + 4) * scale + dy) * side + (x + 4) * scale + dx) * 4;
                        pixels[at] = pixels[at + 1] = pixels[at + 2] = 0;
                    }
                }
            }
        }
        var bitmap = new WriteableBitmap(side, side);
        using (var stream = bitmap.PixelBuffer.AsStream())
        {
            await stream.WriteAsync(pixels);
        }
        bitmap.Invalidate();
        image.Source = bitmap;
        image.Width = image.Height = side;
    }

    /// <summary>Whether devices can connect now: only while Reqly captures.</summary>
    private UIElement CaptureLine()
    {
        if (main.CapturingPort is not null)
        {
            return Line("Reqly is capturing, so devices can connect.", null, null, "");
        }
        var start = new Button { Content = "Start capturing", IsEnabled = !main.IsCaptureBusy };
        start.Click += async (_, _) => await main.StartCapturingFromDevicesAsync();
        var line = Line("Start capturing, so devices can connect.", null, start, "");
        return line;
    }

    /// <summary>The certificate devices need to trust, or how to make one.</summary>
    private UIElement CertificateLine()
    {
        if (main.TrustedCertificateName is not { } name)
        {
            var setUp = new Button { Content = "Set up HTTPS…" };
            setUp.Click += (_, _) => main.ShowHttpsSetup();
            return Line("Set up HTTPS to see the devices' HTTPS traffic.", null, setUp, "");
        }
        return Line(
            $"Devices need Reqly's current certificate, “{name}”.",
            "A device that trusted an earlier Reqly certificate rejects this one. Open the page above on it, install the certificate, and trust it again.",
            null, "");
    }

    // MARK: Building blocks

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

    private static TextBlock Footer(string text) => new()
    {
        Text = text,
        Style = (Style)Application.Current.Resources["SettingsDescriptionStyle"],
        Margin = new Thickness(1, 0, 0, 0),
    };

    /// <summary>A line of a card: an icon, a title and its details, and a control at the end.</summary>
    private static Grid Line(string title, string? details, UIElement? control, string? glyph = null)
    {
        var line = new Grid { ColumnSpacing = 16 };
        // Without an icon, the words start at the card's edge, as on the other cards.
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = glyph is null ? new GridLength(0) : GridLength.Auto });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (glyph is not null)
        {
            line.Children.Add(new FontIcon { Glyph = glyph, FontSize = 16, VerticalAlignment = VerticalAlignment.Center, Foreground = Blocks.Resource("TextFillColorSecondaryBrush") });
        }
        else
        {
            line.ColumnSpacing = 0;
        }
        var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap });
        if (details is not null)
        {
            words.Children.Add(new TextBlock { Text = details, Style = (Style)Application.Current.Resources["SettingsDescriptionStyle"] });
        }
        Grid.SetColumn(words, 1);
        line.Children.Add(words);
        if (control is FrameworkElement element)
        {
            Grid.SetColumn(element, 2);
            element.VerticalAlignment = VerticalAlignment.Center;
            if (glyph is null)
            {
                element.Margin = new Thickness(16, 0, 0, 0);
            }
            line.Children.Add(element);
        }
        return line;
    }
}
