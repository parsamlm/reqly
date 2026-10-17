using System.Globalization;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Reqly.Core;
using Reqly.Traffic;

namespace Reqly.Inspector;

/// <summary>The Request and Response tabs, as the Mac's: the query, the headers, cookies, the body and trailers.</summary>
public sealed partial class InspectorView
{
    private async Task<List<UIElement>> RequestTabAsync(WireDetails shown)
    {
        var parts = new List<UIElement>();
        if (shown.Query.Length > 0)
        {
            var section = Blocks.Section("Query parameters", shown.Query.Length);
            foreach (var parameter in shown.Query)
            {
                section.Children.Add(Blocks.Row(parameter.Name, parameter.Value, monospaced: true));
            }
            parts.Add(section);
        }
        parts.Add(Headers("Headers", shown.RequestHeaders, copies: true));
        if (shown.RequestCookies.Length > 0)
        {
            parts.Add(Cookies(shown.RequestCookies));
        }
        parts.Add(await BodyAsync(shown, isRequest: true, shown.RequestBodySize, "This request has no body."));
        return parts;
    }

    private async Task<List<UIElement>> ResponseTabAsync(WireDetails shown)
    {
        var parts = new List<UIElement>();
        if (shown.ResponseHeaders is not { } headers)
        {
            parts.Add(Blocks.Note(shown.IsTunnel
                ? "Reqly doesn't decrypt this host, so the response isn't readable."
                : "No response yet."));
            return parts;
        }
        parts.Add(Headers("Headers", headers, copies: true));
        if (shown.ResponseCookies.Length > 0)
        {
            parts.Add(Cookies(shown.ResponseCookies));
        }
        parts.Add(await BodyAsync(shown, isRequest: false, shown.ResponseBodySize, "This response has no body."));
        if (shown.ResponseTrailers is { Length: > 0 } trailers)
        {
            parts.Add(Headers("Trailers", trailers, copies: false));
        }
        return parts;
    }

    private async Task<UIElement> BodyAsync(WireDetails shown, bool isRequest, int size, string emptyText)
    {
        if (size == 0 || context is null)
        {
            var empty = Blocks.Section("Body");
            empty.Children.Add(Blocks.Note(emptyText));
            return empty;
        }
        try
        {
            var request = new JsonObject { ["call"] = "presentBody", ["id"] = shown.Id, ["part"] = isRequest ? "request" : "response" };
            var body = Wire.Read<WireBody>(await context.Session.CallAsync(request));
            return new BodyView(context, shown.Id, isRequest, body, ViewerHeight, shown.Path);
        }
        catch (CoreProblem problem)
        {
            return Blocks.Note(problem.Message);
        }
    }

    /// <summary>
    /// Headers in order, as sent. Secrets, such as cookies and authorization, show as dots, each
    /// with Show beside it. Copy copies them all, secrets included.
    /// </summary>
    private StackPanel Headers(string title, WireHeader[] headers, bool copies)
    {
        var copy = copies && headers.Length > 0
            ? Blocks.IconButton("\uE8C8", "Copy headers", () => context?.Copy(string.Join("\n", headers.Select(header => $"{header.Name}: {header.Value}"))))
            : null;
        var section = Blocks.Section(title, headers.Length, copy);
        foreach (var header in headers)
        {
            if (!header.IsSecret)
            {
                section.Children.Add(Blocks.Row(header.Name, header.Value, allMonospaced: true));
                continue;
            }
            var row = Blocks.Row(header.Name, Dots(header.Value), allMonospaced: true);
            var value = (TextBlock)row.Children[1];
            var show = Blocks.Link("Show", () => { }, $"Show {header.Name}");
            show.Click += (_, _) =>
            {
                value.Text = header.Value;
                show.Visibility = Visibility.Collapsed;
            };
            var line = new Grid { ColumnSpacing = 6 };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Remove(value);
            // It moves from the row's second column to the line's first, with Show beside it.
            Grid.SetColumn(value, 0);
            line.Children.Add(value);
            Grid.SetColumn(show, 1);
            line.Children.Add(show);
            Grid.SetColumn(line, 1);
            row.Children.Add(line);
            section.Children.Add(row);
        }
        return section;
    }

    /// <summary>Dots in place of a secret: at least 8, at most 16.</summary>
    private static string Dots(string value) => new('•', Math.Clamp(value.Length, 8, 16));

    /// <summary>The cookies, their values hidden until you show them all.</summary>
    private StackPanel Cookies(WireCookie[] cookies)
    {
        var rows = new List<(TextBlock Value, string Text)>();
        var toggle = Blocks.Link("Show values", () => { });
        var section = Blocks.Section("Cookies", cookies.Length, toggle);
        var isShown = false;
        toggle.Click += (_, _) =>
        {
            isShown = !isShown;
            toggle.Content = isShown ? "Hide values" : "Show values";
            foreach (var (value, text) in rows)
            {
                value.Text = isShown ? text : Dots(text);
            }
        };
        foreach (var cookie in cookies)
        {
            var row = Blocks.Row(cookie.Name.Length > 0 ? cookie.Name : "No name", Dots(cookie.Value), allMonospaced: true);
            var value = (TextBlock)row.Children[1];
            rows.Add((value, cookie.Value));
            var attributes = new List<string>();
            if (cookie.Expires is double expires)
            {
                var date = DateTime.UnixEpoch.AddSeconds(expires).ToLocalTime();
                attributes.Add($"Expires {date.ToString("d", CultureInfo.CurrentCulture)} {date.ToString("t", CultureInfo.CurrentCulture)}");
            }
            else if (cookie.ExpiresText is { } text)
            {
                attributes.Add($"Expires {text}");
            }
            attributes.AddRange(cookie.Attributes);
            if (attributes.Count > 0)
            {
                var lines = new StackPanel();
                row.Children.Remove(value);
                lines.Children.Add(value);
                lines.Children.Add(new TextBlock
                {
                    Text = string.Join(" · ", attributes),
                    TextWrapping = TextWrapping.Wrap,
                    Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                    Foreground = Blocks.Resource("TextFillColorSecondaryBrush"),
                });
                Grid.SetColumn(lines, 1);
                row.Children.Add(lines);
            }
            section.Children.Add(row);
        }
        return section;
    }
}
