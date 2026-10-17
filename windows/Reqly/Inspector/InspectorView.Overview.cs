using System.Globalization;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Reqly.Core;
using Reqly.Traffic;
using Windows.System;

namespace Reqly.Inspector;

/// <summary>The Overview tab, as the Mac's: the comment, decryption, the URL, a failure, rules, script output, and the request and response at a glance.</summary>
public sealed partial class InspectorView
{
    private async Task<List<UIElement>> OverviewTabAsync(WireDetails shown)
    {
        var parts = new List<UIElement>();
        if (shown.Comment is not null || editsComment)
        {
            parts.Add(CommentSection(shown));
        }
        if (await DecryptionNoteAsync(shown) is { } note)
        {
            parts.Add(note);
        }
        if (shown.Url is { } url)
        {
            var section = Blocks.Section("URL");
            section.Children.Add(Blocks.Box(url));
            parts.Add(section);
        }
        if (shown.Failure is { } failure)
        {
            parts.Add(Blocks.Failure(failure));
        }
        if (shown.AppliedRules.Length > 0)
        {
            var section = Blocks.Section("Rules", shown.AppliedRules.Length);
            foreach (var rule in shown.AppliedRules)
            {
                section.Children.Add(RuleRow(rule));
            }
            parts.Add(section);
        }
        if (shown.ScriptOutput.Length > 0)
        {
            var section = Blocks.Section("Script output");
            foreach (var output in shown.ScriptOutput)
            {
                var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(0, 4, 0, 4) };
                label.Children.Add(new FontIcon { Glyph = "\uE943", FontSize = 12, Foreground = Blocks.Resource("TextFillColorSecondaryBrush") });
                label.Children.Add(Blocks.Note($"{output.Rule} · {(output.Part == "request" ? "onRequest" : "onResponse")}"));
                section.Children.Add(label);
                section.Children.Add(Blocks.Box(string.Join("\n", output.Lines)));
            }
            parts.Add(section);
        }

        var request = Blocks.Section("Request");
        request.Children.Add(Blocks.Row("Method", shown.Method));
        if (shown.DeviceInfo is { } device)
        {
            request.Children.Add(Blocks.Row("Device", device.FullName));
        }
        if (shown.Source is { } source)
        {
            request.Children.Add(Blocks.Row("App", source.Name));
            if (source.BundleID is { } bundle)
            {
                request.Children.Add(Blocks.Row("Bundle ID", bundle));
            }
            else if (source.Path is { } path)
            {
                request.Children.Add(Blocks.Row("Path", path));
            }
        }
        request.Children.Add(Blocks.Row("Started", Started(shown.Started)));
        request.Children.Add(Blocks.Row("Sent", Format.Size(shown.BytesSent)));
        parts.Add(request);

        var duration = shown.Ended is double ended ? Format.Duration(ended - shown.Started) : "";
        if (shown.IsTunnel)
        {
            var connection = Blocks.Section("Connection");
            connection.Children.Add(Blocks.Row("HTTPS", TunnelEncryption(shown)));
            if (shown.UpstreamProxy is { } proxy)
            {
                connection.Children.Add(Blocks.Row("Upstream proxy", proxy));
            }
            connection.Children.Add(Blocks.Row("Received", Format.Size(shown.BytesReceived)));
            connection.Children.Add(Blocks.Row("Duration", shown.State == "open" ? "" : duration));
            parts.Add(connection);
            return parts;
        }

        var response = Blocks.Section("Response");
        if (shown.Status is int status)
        {
            response.Children.Add(Blocks.Row("Status", $"{status} {shown.Reason}".Trim()));
            if (shown.Grpc is { } grpc)
            {
                response.Children.Add(Blocks.Row("gRPC status", $"{grpc.Code} {grpc.Name}" + (grpc.Message is { } message ? $": {message}" : "")));
            }
            response.Children.Add(Blocks.Row("Received", Format.Size(shown.BytesReceived)));
            var contentType = shown.ResponseHeaders?.FirstOrDefault(header => header.Name.Equals("Content-Type", StringComparison.OrdinalIgnoreCase))?.Value;
            response.Children.Add(Blocks.Row("Content type", contentType ?? "None"));
            response.Children.Add(Blocks.Row("Duration", duration));
        }
        else
        {
            response.Children.Add(Blocks.Note("No response yet."));
        }
        parts.Add(response);

        var connectionSection = Blocks.Section("Connection");
        connectionSection.Children.Add(Blocks.Row("Protocol", shown.Version));
        if (shown.ServerProtocol is { } serverProtocol)
        {
            connectionSection.Children.Add(Blocks.Row("To the server", serverProtocol));
        }
        if (shown.IsWebSocket)
        {
            connectionSection.Children.Add(Blocks.Row("WebSocket", shown.MessageCount == 1 ? "1 message" : $"{shown.MessageCount:N0} messages"));
        }
        if (shown.Decryption == "decrypted")
        {
            connectionSection.Children.Add(Blocks.Row("HTTPS", "Decrypted by Reqly"));
        }
        else if (shown.Scheme == "https" || shown.TlsVersion is not null)
        {
            // Reqly spoke TLS with the server itself, such as for a request a rule sent on to https.
            connectionSection.Children.Add(Blocks.Row("HTTPS", "Sent over TLS by Reqly"));
        }
        if (shown.ReverseProxy is { } reverse)
        {
            connectionSection.Children.Add(Blocks.Row("Reverse proxy", $"The app sent it to {reverse}"));
        }
        if (shown.UpstreamProxy is { } upstream)
        {
            connectionSection.Children.Add(Blocks.Row("Upstream proxy", upstream));
        }
        if (shown.ClientCertificate is { } certificate)
        {
            connectionSection.Children.Add(Blocks.Row("Client certificate", certificate));
        }
        parts.Add(connectionSection);
        return parts;
    }

    /// <summary>When it started, to the thousandth of a second, in your own date and time formats.</summary>
    private static string Started(double started)
    {
        var date = DateTime.UnixEpoch.AddSeconds(started).ToLocalTime();
        var time = CultureInfo.CurrentCulture.DateTimeFormat.LongTimePattern.Replace("ss", "ss.fff");
        return $"{date.ToString("d", CultureInfo.CurrentCulture)} {date.ToString(time, CultureInfo.CurrentCulture)}";
    }

    /// <summary>What became of a tunnel's encryption: passed through, or a decryption the app refused.</summary>
    private static string TunnelEncryption(WireDetails shown) => shown.Decryption == "certificateRejected"
        ? "Reqly tried to decrypt it, but the app's handshake failed"
        : "Encrypted, passed through untouched";

    private static Grid RuleRow(WireRule rule)
    {
        var (title, glyph) = (Rules.RuleKinds.Of(rule.Kind).Title, Rules.RuleKinds.Of(rule.Kind).Glyph);
        var row = Blocks.Row("", rule.Detail);
        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        label.Children.Add(new FontIcon { Glyph = glyph, FontSize = 12, Foreground = Blocks.Resource("TextFillColorSecondaryBrush") });
        label.Children.Add(new TextBlock { Text = rule.Name, Foreground = Blocks.Resource("TextFillColorSecondaryBrush"), TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 110 });
        ToolTipService.SetToolTip(label, $"{title}: {rule.Name}");
        row.Children.RemoveAt(0);
        row.Children.Insert(0, label);
        return row;
    }

    // MARK: The comment

    /// <summary>
    /// The comment, in a field you can type in. It's saved when you press Enter or leave the field;
    /// spaces around it go, and an empty one removes it.
    /// </summary>
    private StackPanel CommentSection(WireDetails shown)
    {
        var section = Blocks.Section("Comment");
        var field = new TextBox
        {
            Text = shown.Comment ?? "",
            PlaceholderText = "Add a comment",
            TextWrapping = TextWrapping.Wrap,
            MaxHeight = 8 * 20 + 12,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(field, "Comment");
        var saved = shown.Comment ?? "";
        async Task SaveAsync()
        {
            if (field.Text.Trim() == saved.Trim())
            {
                return;
            }
            saved = field.Text;
            await AnnotateAsync(new JsonObject { ["comment"] = field.Text });
        }
        field.KeyDown += async (_, args) =>
        {
            if (args.Key == VirtualKey.Enter)
            {
                args.Handled = true;
                await SaveAsync();
            }
        };
        field.LostFocus += async (_, _) => await SaveAsync();
        if (editsComment)
        {
            editsComment = false;
            field.Loaded += (_, _) => field.Focus(FocusState.Programmatic);
        }
        section.Children.Add(field);
        return section;
    }

    // MARK: Decryption

    /// <summary>
    /// What happens to the request's host from now on, which may differ from what happened to this
    /// request, with the action that fits, as the Mac's detail pane says.
    /// </summary>
    private async Task<InfoBar?> DecryptionNoteAsync(WireDetails shown)
    {
        if (https is null || shown.Decryption == "plain")
        {
            return null;
        }
        var host = shown.Host;
        var isDecrypting = await https.DecryptsAsync(host);
        const string Lock = "\uE72E", Unlock = "\uE785", Warning = "\uE7BA";
        (string Text, string Glyph, bool Decrypts) note = (shown.Decryption, isDecrypting) switch
        {
            ("encryptedTunnel", false) => ("This connection is encrypted, so Reqly can't show what's inside.", Lock, true),
            ("encryptedTunnel", true) => ($"Reqly now decrypts {host}. Its next requests show up decrypted.", Unlock, false),
            ("decrypted", true) => ("Reqly decrypted this request.", Unlock, false),
            ("certificateRejected", true) => shown.Device is { } device
                // A device keeps the certificate it was given, so a new one on the PC needs installing there too.
                ? ($"{device} may trust an earlier Reqly certificate. Install the current one on it, or stop decrypting {host} to let its traffic through, encrypted.", Warning, false)
                : ($"Stopping decryption for {host} lets its traffic through again, encrypted.", Warning, false),
            _ => ($"Reqly no longer decrypts {host}. Its connections pass through encrypted.", Lock, true),
        };
        var action = new Button
        {
            Content = note.Decrypts ? $"Decrypt {host}" : $"Stop decrypting {host}",
            IsEnabled = !https.IsWorking,
        };
        if (note.Decrypts && shown.Decryption == "encryptedTunnel")
        {
            action.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        }
        action.Click += async (_, _) =>
        {
            if (note.Decrypts)
            {
                await https.DecryptAsync(host);
            }
            else
            {
                await https.StopDecryptingAsync(host);
            }
        };
        return new InfoBar
        {
            IsOpen = true,
            IsClosable = false,
            Message = note.Text,
            IconSource = new FontIconSource { Glyph = note.Glyph },
            Severity = note.Glyph == Warning ? InfoBarSeverity.Warning : InfoBarSeverity.Informational,
            ActionButton = action,
        };
    }

    /// <summary>The decryption note's words, for the self-check.</summary>
    public string? DecryptionNoteText =>
        TabContent.Children.OfType<InfoBar>().FirstOrDefault() is { } bar ? $"{bar.Message} · {(bar.ActionButton as Button)?.Content}" : null;
}
