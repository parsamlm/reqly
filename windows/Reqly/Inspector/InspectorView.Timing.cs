using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Reqly.Core;
using Reqly.Traffic;

namespace Reqly.Inspector;

/// <summary>The Timing tab, as the Mac's: a waterfall of the exchange's steps, its total, and its connection.</summary>
public sealed partial class InspectorView
{
    private static readonly Dictionary<string, string> StepTitles = new()
    {
        ["queued"] = "Queued",
        ["dnsLookup"] = "DNS lookup",
        ["connecting"] = "Connecting",
        ["tlsHandshake"] = "TLS handshake",
        ["requestSent"] = "Request sent",
        ["waiting"] = "Waiting for server",
        ["downloading"] = "Downloading",
        ["open"] = "Connection open",
    };

    private List<UIElement> TimingParts(WireDetails shown)
    {
        var parts = new List<UIElement>();
        if (shown.Failure is { } failure)
        {
            parts.Add(Blocks.Failure(failure));
        }
        var isFinished = shown.State is "completed" or "failed";
        if (shown.Phases.Length > 0 || !isFinished)
        {
            var waterfall = new StackPanel();
            // From the start to the later of the end and the last step, never less than a microsecond.
            var start = shown.Started;
            var end = Math.Max(shown.Ended ?? start, shown.Phases.Length > 0 ? shown.Phases.Max(phase => phase.End) : start);
            var span = Math.Max(end - start, 0.000001);
            for (var index = 0; index < shown.Phases.Length; index++)
            {
                var phase = shown.Phases[index];
                var isFailedStep = shown.State == "failed" && index == shown.Phases.Length - 1;
                waterfall.Children.Add(StepRow(
                    StepTitles.GetValueOrDefault(phase.Step, phase.Step), Format.Duration(phase.End - phase.Start, showingTenths: true),
                    (phase.Start - start) / span, (phase.End - phase.Start) / span, StepBrush(phase.Step, isFailedStep)));
            }
            var total = shown.State == "open" ? "Still open" : isFinished && shown.Ended is double ended ? Format.Duration(ended - start, showingTenths: true) : "In progress";
            waterfall.Children.Add(StepRow("Total", total, 0, 0, null, isTotal: true));
            parts.Add(waterfall);
        }

        var connection = Blocks.Section("Connection");
        if (shown.IsTunnel)
        {
            connection.Children.Add(Blocks.Row("HTTPS", TunnelEncryption(shown)));
        }
        else
        {
            connection.Children.Add(Blocks.Row("Protocol", shown.Version));
            if (shown.ServerProtocol is { } serverProtocol)
            {
                connection.Children.Add(Blocks.Row("To the server", serverProtocol));
            }
        }
        if (shown.RemoteAddress is { } address)
        {
            connection.Children.Add(Blocks.Row("Remote address", address, monospaced: true));
        }
        if (shown.TlsVersion is { } tls)
        {
            connection.Children.Add(Blocks.Row("TLS", tls));
        }
        if (!shown.IsTunnel && (shown.ReusedConnection || shown.ConnectStarted is not null))
        {
            connection.Children.Add(Blocks.Row("Reused connection", shown.ReusedConnection ? "Yes" : "No"));
        }
        parts.Add(connection);
        return parts;
    }

    /// <summary>Waiting for the server in the accent color, the response coming in in a lighter accent, the rest in gray, and a failed step in red.</summary>
    private static Brush StepBrush(string step, bool failed)
    {
        if (failed)
        {
            return Blocks.Resource("SystemFillColorCriticalBrush");
        }
        var accent = (Windows.UI.Color)Application.Current.Resources["SystemAccentColor"];
        return step switch
        {
            "waiting" => new SolidColorBrush(accent),
            "downloading" or "open" => new SolidColorBrush(accent) { Opacity = 0.5 },
            _ => Blocks.Resource("ControlStrongFillColorDefaultBrush"),
        };
    }

    /// <summary>A step: its title, a bar where it falls in the exchange, and how long it took.</summary>
    private static Grid StepRow(string title, string value, double from, double length, Brush? bar, bool isTotal = false)
    {
        var row = new Grid
        {
            ColumnSpacing = 12,
            MinHeight = 30,
            BorderThickness = new Thickness(0, 0, 0, 1),
            BorderBrush = Blocks.Resource("DividerStrokeColorDefaultBrush"),
        };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(72) });
        var name = new TextBlock
        {
            Text = title,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = isTotal ? Blocks.Resource("TextFillColorPrimaryBrush") : Blocks.Resource("TextFillColorSecondaryBrush"),
            FontWeight = isTotal ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
        };
        row.Children.Add(name);
        if (bar is not null)
        {
            // The bar's place and length are parts of the whole, at least 3 pixels long.
            var track = new Grid { VerticalAlignment = VerticalAlignment.Center };
            var before = Math.Clamp(from, 0, 1);
            var during = Math.Clamp(length, 0, 1 - before);
            track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(before, GridUnitType.Star) });
            track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(during, 0.0001), GridUnitType.Star), MinWidth = 3 });
            track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(1 - before - during, 0), GridUnitType.Star) });
            var capsule = new Rectangle { Height = 8, RadiusX = 4, RadiusY = 4, Fill = bar };
            Grid.SetColumn(capsule, 1);
            track.Children.Add(capsule);
            Grid.SetColumn(track, 1);
            row.Children.Add(track);
        }
        var duration = new TextBlock { Text = value, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(duration, 2);
        row.Children.Add(duration);
        return row;
    }
}
