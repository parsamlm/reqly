using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Reqly.Core;
using Reqly.Devices;

namespace Reqly;

/// <summary>Phones and tablets on the network, as on the Mac: the Devices window, the question each new one asks, and their names.</summary>
public sealed partial class MainWindow
{
    private DevicesModel? devices;
    private DevicesWindow? devicesWindow;
    /// <summary>Whether a device's question shows. Only one dialog shows at a time.</summary>
    private bool isAskingAboutDevice;

    private async Task OpenDevicesAsync(CoreSession session)
    {
        devices = new DevicesModel(session);
        devices.Changed += () =>
        {
            ShowStatus();
            _ = AskAboutDevicesAsync();
        };
        // A test run passes no, so nothing listens on the network.
        await devices.OpenAsync(options.DevicesFile, options.AllowsNetworkDevices ?? settings.AllowsNetworkDevices);
        if (sidebar is not null)
        {
            sidebar.RenameDevice = RenameDeviceAsync;
        }
        Log($"devices: {devices.Devices.Known.Length} let in, allowed {devices.Devices.AllowsNetworkDevices}");
    }

    public void ShowDevices()
    {
        if (file is not null)
        {
            App.Current.Main?.ShowDevices();
            return;
        }
        if (devices is null)
        {
            return;
        }
        if (devicesWindow is null)
        {
            devicesWindow = new DevicesWindow(this, devices);
            devicesWindow.Closed += (_, _) => devicesWindow = null;
        }
        devicesWindow.Activate();
    }

    private void OnDevicesClicked(object sender, RoutedEventArgs e) => ShowDevices();

    /// <summary>Lets devices on the network connect, or only this PC, and keeps the choice.</summary>
    public async Task SetAllowsNetworkDevicesAsync(bool allows)
    {
        if (devices is null)
        {
            return;
        }
        settings.AllowsNetworkDevices = allows;
        settings.Save();
        await devices.SetAllowsNetworkDevicesAsync(allows);
        Log($"devices on the network: {(allows ? "allowed" : "not allowed")}");
    }

    public Task StartCapturingFromDevicesAsync() => capture == Capture.Stopped ? StartCapturingAsync() : Task.CompletedTask;

    /// <summary>The certificate devices need to trust, while this PC trusts it.</summary>
    public string? TrustedCertificateName => https is { IsTrusted: true, Certificate: { } certificate } ? certificate.Name : null;

    public void ShowHttpsSetup()
    {
        BringForward();
        _ = ShowSetupAsync();
    }

    public void CopyAddress(string address) => CopyText(address);

    /// <summary>Why capturing last failed to start or stop, while it does.</summary>
    public string? CaptureProblem => problem;

    private Welcome.WelcomeWindow? welcomeWindow;

    private void OnWelcomeClicked(object sender, RoutedEventArgs e) => ShowWelcome();

    /// <summary>The first-run guide. A file's window opens the main window's.</summary>
    public void ShowWelcome()
    {
        if (file is not null)
        {
            App.Current.Main?.ShowWelcome();
            return;
        }
        if (https is null)
        {
            return;
        }
        if (welcomeWindow is null)
        {
            welcomeWindow = new Welcome.WelcomeWindow(this, https);
            welcomeWindow.Closed += (_, _) => welcomeWindow = null;
        }
        welcomeWindow.Activate();
    }

    /// <summary>Opens the guide the first time Reqly opens.</summary>
    private void ShowWelcomeTheFirstTime()
    {
        if (settings.HasSeenWelcome || options.HasSeenWelcome)
        {
            return;
        }
        settings.HasSeenWelcome = true;
        settings.Save();
        ShowWelcome();
    }

    /// <summary>Reqly's certificate in DER, for devices and emulators to install, while this PC trusts it.</summary>
    public byte[]? TrustedCertificate => https?.CertificateForDevices;

    /// <summary>The session being captured, which runs adb for the emulators.</summary>
    public CoreSession? LiveSession => file is null ? session : null;

    /// <summary>
    /// Asks about the first device waiting, then the next, as long as any wait. Another dialog
    /// may be showing, such as HTTPS setup; the question waits for it.
    /// </summary>
    private async Task AskAboutDevicesAsync()
    {
        if (isAskingAboutDevice || devices is null)
        {
            return;
        }
        isAskingAboutDevice = true;
        try
        {
            while (devices.Devices.Waiting.FirstOrDefault() is { } device)
            {
                if (Root.XamlRoot is null || setup is not null)
                {
                    await Task.Delay(1000);
                    continue;
                }
                var name = new TextBox { Header = "Name", PlaceholderText = "Name it, if you like" };
                var words = new StackPanel { Spacing = 12, Width = 380 };
                words.Children.Add(new FontIcon { Glyph = "\uE8EA", FontSize = 36, HorizontalAlignment = HorizontalAlignment.Left });
                words.Children.Add(new TextBlock
                {
                    Text = $"A device at {device.Address} wants to send its traffic through Reqly. Allow it only if it's yours.",
                    TextWrapping = TextWrapping.Wrap,
                });
                words.Children.Add(name);
                var others = devices.Devices.Waiting.Length - 1;
                if (others > 0)
                {
                    words.Children.Add(global::Reqly.Inspector.Blocks.Note(others == 1 ? "1 more device is waiting." : $"{others} more devices are waiting."));
                }
                var dialog = new ContentDialog
                {
                    XamlRoot = Root.XamlRoot,
                    Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"],
                    Title = "Let this device use Reqly?",
                    Content = words,
                    PrimaryButtonText = "Allow",
                    CloseButtonText = "Don't allow",
                    DefaultButton = ContentDialogButton.Primary,
                };
                ContentDialogResult answer;
                try
                {
                    answer = await dialog.ShowAsync();
                }
                catch (Exception error)
                {
                    // Another dialog shows; ask once it's gone.
                    Log($"the device's question didn't show yet: {error.Message}");
                    await Task.Delay(1000);
                    continue;
                }
                var allow = answer == ContentDialogResult.Primary;
                await devices.DecideAsync(device.Id, allow, allow ? name.Text : null);
                Log($"{(allow ? "let in" : "turned away")} the device at {device.Address}");
            }
        }
        finally
        {
            isAskingAboutDevice = false;
        }
    }

    /// <summary>Names a device's traffic, from now on and in the list already.</summary>
    private async Task RenameDeviceAsync(string id, string shown)
    {
        if (devices is null || Root.XamlRoot is null)
        {
            return;
        }
        var name = new TextBox { Header = "Name", Text = shown };
        var words = new StackPanel { Spacing = 12, Width = 360 };
        words.Children.Add(new TextBlock { Text = "Its traffic shows with this name.", TextWrapping = TextWrapping.Wrap });
        words.Children.Add(name);
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"],
            Title = $"Rename {shown}",
            Content = words,
            PrimaryButtonText = "Rename",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        name.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = name.Text.Trim().Length > 0;
        try
        {
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            {
                await devices.RenameAsync(id, name.Text);
            }
        }
        catch (Exception error)
        {
            Log($"the rename didn't show: {error.Message}");
        }
    }
}
