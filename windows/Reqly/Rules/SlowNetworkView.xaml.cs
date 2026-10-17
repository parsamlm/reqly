using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Reqly.Core;
using Reqly.Inspector;
using Windows.Globalization.NumberFormatting;
using Windows.System;

namespace Reqly.Rules;

/// <summary>
/// Slow Network, as on the Mac: a profile, or speeds, latency and loss of your own, and the hosts
/// it slows down. Each change applies at once.
/// </summary>
public sealed partial class SlowNetworkView : UserControl
{
    private const string Custom = "Custom";

    private readonly RulesModel rules;
    private bool isShowing;

    public SlowNetworkView(RulesModel rules)
    {
        this.rules = rules;
        InitializeComponent();
        foreach (var preset in rules.Presets)
        {
            Profile.Items.Add(preset.Name);
        }
        Profile.Items.Add(Custom);
        var whole = new DecimalFormatter { FractionDigits = 0, IsGrouped = true, NumberRounder = new IncrementNumberRounder { Increment = 1 } };
        Download.NumberFormatter = whole;
        Upload.NumberFormatter = whole;
        Latency.NumberFormatter = new DecimalFormatter { FractionDigits = 0, IsGrouped = true, NumberRounder = new IncrementNumberRounder { Increment = 1 } };
        Loss.NumberFormatter = new DecimalFormatter { FractionDigits = 0, NumberRounder = new IncrementNumberRounder { Increment = 0.1 } };
        Loaded += (_, _) =>
        {
            rules.Changed += Show;
            Show();
        };
        Unloaded += (_, _) => rules.Changed -= Show;
    }

    private WireNetwork Network => rules.Rules.Network;

    /// <summary>What the page shows, for the self-check.</summary>
    public string Describe() =>
        $"{Profile.SelectedItem} · {Download.Value} / {Upload.Value} kbit/s · {Latency.Value} ms · {Loss.Value} % · hosts: {(Network.Hosts.Length == 0 ? "every host" : string.Join(", ", Network.Hosts))}";

    private void Show()
    {
        isShowing = true;
        KindSwitch.IsOn = rules.IsOn("slowNetwork");
        var profile = Network.Profile;
        Profile.SelectedItem = Profile.Items.Contains(profile.Name) ? profile.Name : Custom;
        // Speeds show in kilobits a second, as networks are usually described.
        Download.Value = profile.DownloadBytesPerSecond is long download ? download * 8 / 1000 : double.NaN;
        Upload.Value = profile.UploadBytesPerSecond is long upload ? upload * 8 / 1000 : double.NaN;
        Latency.Value = profile.Latency > 0 ? profile.Latency : double.NaN;
        Loss.Value = profile.PacketLoss > 0 ? Math.Round(profile.PacketLoss * 100, 1) : double.NaN;
        ShowHosts();
        isShowing = false;
    }

    private void ShowHosts()
    {
        HostRows.Children.Clear();
        foreach (var host in Network.Hosts)
        {
            var row = new Grid { Padding = new Thickness(16, 8, 12, 8), ColumnSpacing = 8, BorderThickness = new Thickness(0, 0, 0, 1), BorderBrush = Blocks.Resource("CardStrokeColorDefaultBrush") };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new TextBlock { Text = host, FontFamily = Blocks.Mono, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
            var shown = host;
            var remove = Blocks.IconButton("", $"Remove {host}", () => _ = SetAsync(Network with { Hosts = [.. Network.Hosts.Where(other => other != shown)] }));
            ToolTipService.SetToolTip(remove, "Remove");
            Grid.SetColumn(remove, 1);
            row.Children.Add(remove);
            HostRows.Children.Add(row);
        }
        EveryHost.Visibility = Network.Hosts.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private Task SetAsync(WireNetwork network) => rules.SetNetworkAsync(network);

    private void OnKindToggled(object sender, RoutedEventArgs e)
    {
        if (!isShowing && KindSwitch.IsOn != rules.IsOn("slowNetwork"))
        {
            _ = rules.SetOnAsync("slowNetwork", KindSwitch.IsOn);
        }
    }

    /// <summary>Picking a profile sets all its numbers. Picking Custom keeps the numbers as they are.</summary>
    private void OnProfileChanged(object sender, SelectionChangedEventArgs e)
    {
        if (isShowing || Profile.SelectedItem is not string name || name == Network.Profile.Name)
        {
            return;
        }
        var preset = rules.Presets.FirstOrDefault(preset => preset.Name == name);
        _ = SetAsync(Network with { Profile = preset ?? Network.Profile with { Name = Custom } });
    }

    /// <summary>Changing a number makes the profile a custom one.</summary>
    private void OnNumberChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (isShowing)
        {
            return;
        }
        var profile = Network.Profile with
        {
            DownloadBytesPerSecond = Bytes(Download.Value),
            UploadBytesPerSecond = Bytes(Upload.Value),
            Latency = double.IsNaN(Latency.Value) ? 0 : (int)Math.Max(Math.Round(Latency.Value), 0),
            PacketLoss = double.IsNaN(Loss.Value) ? 0 : Math.Min(Math.Max(Loss.Value, 0), 100) / 100,
        };
        if (profile == Network.Profile)
        {
            return;
        }
        _ = SetAsync(Network with { Profile = profile with { Name = Custom } });
    }

    /// <summary>A speed in bytes a second, for one in kilobits a second. None, or 0, is no limit.</summary>
    private static long? Bytes(double kilobits) =>
        double.IsNaN(kilobits) || kilobits <= 0 ? null : (long)Math.Round(kilobits) * 1000 / 8;

    private void OnNewHostChanged(object sender, TextChangedEventArgs e) => AddHostButton.IsEnabled = NewHost.Text.Trim().Length > 0;

    private void OnNewHostKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            AddHost();
        }
    }

    private void OnAddHostClicked(object sender, RoutedEventArgs e) => AddHost();

    private void AddHost()
    {
        var host = NewHost.Text.Trim().ToLowerInvariant();
        if (host.Length == 0)
        {
            return;
        }
        if (!Network.Hosts.Contains(host))
        {
            _ = SetAsync(Network with { Hosts = [.. Network.Hosts, host] });
        }
        NewHost.Text = "";
    }
}
