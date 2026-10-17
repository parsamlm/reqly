using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace Reqly.Https;

/// <summary>The HTTPS page of Settings: Reqly's certificate, and the hosts it decrypts.</summary>
public sealed partial class HttpsSettingsView : UserControl
{
    private readonly HttpsModel https;
    /// <summary>Each host's row, kept while the host stays on the list, so its switch keeps its focus.</summary>
    private readonly Dictionary<string, HostRow> rows = [];
    private bool isShowing;

    public HttpsSettingsView(HttpsModel https)
    {
        this.https = https;
        InitializeComponent();
        Loaded += (_, _) =>
        {
            https.Changed += Show;
            Show();
        };
        Unloaded += (_, _) => https.Changed -= Show;
    }

    private void Show()
    {
        isShowing = true;
        ShowCertificate();
        ShowHosts();
        EveryHost.IsOn = https.Hosts.IncludesEveryHost;
        HostsFooter.Text = https.Hosts.IncludesEveryHost
            ? "Reqly decrypts every host except the ones switched off here. Use * to include subdomains, like *.weatherly.dev."
            : "Traffic to other hosts passes through Reqly still encrypted. Use * to include subdomains, like *.weatherly.dev.";
        isShowing = false;
    }

    // MARK: The certificate

    private void ShowCertificate()
    {
        var created = https.Certificate is { } certificate ? $"Created {certificate.Created:d} · " : "";
        (string Title, string Details, string? Glyph, string? Badge, string? Button) look = https.Status switch
        {
            HttpsModel.Phase.Checking => ("Checking Reqly's certificate…", "", null, null, null),
            HttpsModel.Phase.Working => (https.Message ?? "", "", null, null, null),
            HttpsModel.Phase.Trusted => (
                "The Reqly certificate is installed and trusted", created + "It never leaves this PC",
                "\uE73E", "AccentFillColorDefaultBrush", "Open certificate manager"),
            HttpsModel.Phase.NotTrusted => (
                "Windows doesn't trust the Reqly certificate",
                "Reqly decrypts nothing until it does. Windows asks you to confirm.",
                "\uE7BA", "SystemFillColorCautionBrush", "Trust certificate…"),
            HttpsModel.Phase.Failed => (
                "HTTPS isn't set up", https.Message ?? "", "\uE7BA", "SystemFillColorCriticalBrush", "Try again"),
            _ => (
                "HTTPS isn't set up",
                "To read HTTPS traffic, your PC needs to trust a certificate that Reqly creates just for you. It never leaves this PC.",
                "\uE72E", "ControlStrongFillColorDefaultBrush", "Install certificate…"),
        };
        var (title, details, glyph, badge, button) = look;
        CertificateTitle.Text = title;
        CertificateDetails.Text = details;
        CertificateDetails.Visibility = details.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        Progress.IsActive = glyph is null;
        Badge.Visibility = glyph is null ? Visibility.Collapsed : Visibility.Visible;
        BadgeIcon.Glyph = glyph ?? "";
        Badge.Background = badge is null ? null : (Brush)Application.Current.Resources[badge];
        CertificateButton.Content = button;
        CertificateButton.Visibility = button is null ? Visibility.Collapsed : Visibility.Visible;
        ToolTipService.SetToolTip(
            CertificateButton,
            https.Status == HttpsModel.Phase.Trusted && https.Certificate is { } shown
                ? $"Look for “{shown.Name}” under Trusted Root Certification Authorities, then Certificates."
                : null);
        RemoveCard.Visibility = https.HasCertificate ? Visibility.Visible : Visibility.Collapsed;
        RemoveButton.IsEnabled = !https.IsWorking;
    }

    private async void OnCertificateButtonClicked(object sender, RoutedEventArgs e)
    {
        if (https.Status == HttpsModel.Phase.Trusted)
        {
            // Your user's certificates, in Windows' own manager.
            Process.Start(new ProcessStartInfo("certmgr.msc") { UseShellExecute = true });
            return;
        }
        await https.SetUpAsync();
    }

    private async void OnRemoveClicked(object sender, RoutedEventArgs e)
    {
        var confirm = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"],
            Title = "Remove Reqly's certificate?",
            Content = new TextBlock
            {
                TextWrapping = TextWrapping.Wrap,
                Text = https.IsTrusted
                    ? "Reqly stops decrypting HTTPS, and Windows no longer trusts its certificate. Windows asks you to confirm. You can set up HTTPS again at any time."
                    : "Reqly removes its certificate and its key from this PC. You can set up HTTPS again at any time.",
            },
            PrimaryButtonText = "Remove certificate",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        try
        {
            if (await confirm.ShowAsync() != ContentDialogResult.Primary)
            {
                return;
            }
        }
        catch (Exception error)
        {
            // Only one dialog shows at a time, such as setup in the main window.
            AppLog.Write($"couldn't ask about removing the certificate: {error.Message}");
            return;
        }
        await https.RemoveAsync();
    }

    // MARK: The hosts

    private void ShowHosts()
    {
        var entries = https.Hosts.Entries;
        foreach (var gone in rows.Keys.Except(entries.Select(entry => entry.Pattern)).ToList())
        {
            HostRows.Children.Remove(rows[gone].View);
            rows.Remove(gone);
        }
        for (var index = 0; index < entries.Length; index++)
        {
            var entry = entries[index];
            if (!rows.TryGetValue(entry.Pattern, out var row))
            {
                row = new HostRow(entry.Pattern, https);
                rows[entry.Pattern] = row;
            }
            row.Show(entry.IsOn);
            var at = HostRows.Children.IndexOf(row.View);
            if (at != index)
            {
                if (at >= 0)
                {
                    HostRows.Children.RemoveAt(at);
                }
                HostRows.Children.Insert(index, row.View);
            }
        }
        NoHosts.Visibility = entries.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void OnAddHostClicked(object sender, RoutedEventArgs e) => await AddHostAsync();

    private async void OnNewHostKeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            await AddHostAsync();
        }
    }

    private void OnNewHostChanged(object sender, TextChangedEventArgs e) => AddProblem.Visibility = Visibility.Collapsed;

    private async Task AddHostAsync()
    {
        var text = NewHost.Text;
        if (string.IsNullOrWhiteSpace(text))
        {
            return;
        }
        if (await https.AddHostAsync(text) is { } problem)
        {
            AddProblem.Text = problem;
            AddProblem.Visibility = Visibility.Visible;
            return;
        }
        NewHost.Text = "";
    }

    private async void OnEveryHostToggled(object sender, RoutedEventArgs e)
    {
        if (!isShowing && EveryHost.IsOn != https.Hosts.IncludesEveryHost)
        {
            await https.SetDecryptsEveryHostAsync(EveryHost.IsOn);
        }
    }

    /// <summary>A host on the list, with its switch and a button to remove it.</summary>
    private sealed class HostRow
    {
        private readonly string pattern;
        private readonly HttpsModel https;
        private readonly ToggleSwitch toggle;
        private bool isShowing;

        public Grid View { get; }

        public HostRow(string pattern, HttpsModel https)
        {
            this.pattern = pattern;
            this.https = https;
            View = new Grid
            {
                Padding = new Thickness(16, 6, 12, 6),
                ColumnSpacing = 8,
                BorderThickness = new Thickness(0, 0, 0, 1),
                BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"],
            };
            View.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            View.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            View.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            View.Children.Add(new TextBlock
            {
                Text = pattern,
                FontFamily = new FontFamily("Cascadia Mono, Consolas"),
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            toggle = new ToggleSwitch { MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toggle, $"Decrypt {pattern}");
            toggle.Toggled += OnToggled;
            Grid.SetColumn(toggle, 1);
            View.Children.Add(toggle);
            var remove = new Button
            {
                Content = new FontIcon { Glyph = "\uE74D", FontSize = 14 },
                VerticalAlignment = VerticalAlignment.Center,
                Padding = new Thickness(8),
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new Thickness(0),
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(remove, $"Remove {pattern}");
            ToolTipService.SetToolTip(remove, "Remove");
            remove.Click += async (_, _) => await https.RemoveHostAsync(pattern);
            Grid.SetColumn(remove, 2);
            View.Children.Add(remove);
        }

        public void Show(bool isOn)
        {
            isShowing = true;
            toggle.IsOn = isOn;
            isShowing = false;
        }

        private async void OnToggled(object sender, RoutedEventArgs e)
        {
            if (!isShowing)
            {
                await https.SetDecryptsAsync(pattern, toggle.IsOn);
            }
        }
    }
}
