using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace Reqly.Settings;

/// <summary>The General page of Settings: the proxy port, how Reqly starts and goes on, and what it does to your proxy settings.</summary>
public sealed partial class GeneralSettingsView : UserControl
{
    /// <summary>The ports Reqly can listen on, as on the Mac: the ones above the well-known ports.</summary>
    public const int LowestPort = 1024;
    public const int HighestPort = 65535;

    private readonly MainWindow main;
    /// <summary>Why the port typed can't be used, shown in place of the port's description.</summary>
    private string? portProblem;
    private bool isShowing;

    public GeneralSettingsView(MainWindow main)
    {
        this.main = main;
        InitializeComponent();
        PortBox.Text = main.Settings.ProxyPort.ToString(CultureInfo.InvariantCulture);
        Loaded += (_, _) =>
        {
            main.CaptureChanged += Show;
            App.Current.Updates.Changed += Show;
            Show();
        };
        Unloaded += (_, _) =>
        {
            main.CaptureChanged -= Show;
            App.Current.Updates.Changed -= Show;
        };
    }

    private void Show()
    {
        isShowing = true;
        PortDescription.Text = portProblem ?? "Reqly listens on this port on your PC. Change it if another app already uses it.";
        if (portProblem is null)
        {
            PortDescription.ClearValue(TextBlock.ForegroundProperty);
        }
        else
        {
            PortDescription.Foreground = (Brush)Application.Current.Resources["SystemFillColorCriticalBrush"];
        }
        // Capturing keeps the port it started on until it starts again.
        var isOnOldPort = main.CapturingPort is int listening && listening != main.Port;
        RestartCard.Visibility = isOnOldPort ? Visibility.Visible : Visibility.Collapsed;
        RestartText.Text = $"Reqly uses port {main.Port} the next time you start capturing.";
        RestartButton.IsEnabled = !main.IsCaptureBusy;
        StartsCapturing.IsOn = main.Settings.StartsCapturingOnLaunch;
        ShowsNotificationIcon.IsOn = main.Settings.ShowsNotificationIcon;
        var updates = App.Current.Updates;
        ChecksForUpdates.IsOn = main.Settings.ChecksForUpdates;
        VersionText.Text = $"Reqly {Help.AppInfo.Version}";
        UpdateStatus.Text = updates.Description;
        UpdateButton.Content = updates.ReadyVersion is null ? "Check now" : "Restart to update…";
        UpdateButton.IsEnabled = updates.CanUpdate && updates.Status != Updates.UpdatesModel.State.Checking;
        if (main.SetsSystemProxy)
        {
            NetworkIcon.Glyph = "";
            NetworkTitle.Text = "Always restored";
            NetworkDetails.Text = "Reqly puts your proxy settings back when you stop capturing, even if it quits unexpectedly.";
        }
        else
        {
            NetworkIcon.Glyph = "";
            NetworkTitle.Text = "Left alone";
            NetworkDetails.Text = $"This copy of Reqly doesn't change your proxy settings, so it captures only the apps you point at 127.0.0.1, port {main.CapturingPort ?? main.Port}.";
        }
        isShowing = false;
    }

    private void OnPortKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            SavePort();
        }
    }

    private void OnPortLostFocus(object sender, RoutedEventArgs e) => SavePort();

    private void SavePort()
    {
        var text = PortBox.Text.Trim();
        if (!int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var port) || port < LowestPort || port > HighestPort)
        {
            portProblem = $"Enter a port from {LowestPort} to {HighestPort}.";
            Show();
            return;
        }
        if (main.Connections?.Connections.ReverseProxies.Any(proxy => proxy.LocalPort == port) == true)
        {
            portProblem = $"A reverse proxy listens on port {port}. Choose another port.";
            Show();
            return;
        }
        portProblem = null;
        PortBox.Text = port.ToString(CultureInfo.InvariantCulture);
        main.SetPort(port);
        Show();
    }

    private async void OnRestartClicked(object sender, RoutedEventArgs e) => await main.RestartCapturingAsync();

    private void OnStartsCapturingToggled(object sender, RoutedEventArgs e)
    {
        if (isShowing || StartsCapturing.IsOn == main.Settings.StartsCapturingOnLaunch)
        {
            return;
        }
        main.Settings.StartsCapturingOnLaunch = StartsCapturing.IsOn;
        main.Settings.Save();
    }

    private void OnChecksForUpdatesToggled(object sender, RoutedEventArgs e)
    {
        if (isShowing || ChecksForUpdates.IsOn == main.Settings.ChecksForUpdates)
        {
            return;
        }
        main.Settings.ChecksForUpdates = ChecksForUpdates.IsOn;
        main.Settings.Save();
    }

    private async void OnUpdateButtonClicked(object sender, RoutedEventArgs e) => await Updates.UpdateDialog.ShowAsync(XamlRoot);

    private void OnShowsNotificationIconToggled(object sender, RoutedEventArgs e)
    {
        if (!isShowing)
        {
            App.Current.SetShowsNotificationIcon(ShowsNotificationIcon.IsOn);
        }
    }
}
