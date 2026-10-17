using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Reqly.Core;
using Windows.System;

namespace Reqly.Inspector;

/// <summary>
/// The details pane while the selected request or response waits at a breakpoint, as the Mac's
/// paused editor: what it holds, ready to edit, and the choice to continue or cancel it.
/// </summary>
public sealed partial class PausedEditor : UserControl
{
    private static readonly string[] CommonMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"];

    private readonly WirePaused paused;
    /// <summary>Lets it go on with the edits, or with none, cancels it, and says what to fix if it can't go on.</summary>
    private readonly Func<JsonObject?, Task<string?>> decide;
    private readonly List<(TextBox Name, TextBox Value, WireHeader? Original)> headers = [];
    private readonly StackPanel headerRows = new() { Spacing = 6 };
    private readonly TextBlock headerCount = new() { Foreground = Blocks.Resource("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center };
    private readonly ComboBox method = new() { MinWidth = 100 };
    private readonly TextBox url = new() { FontFamily = Blocks.Mono, FontSize = 12 };
    private readonly TextBox status = new() { Width = 72, FontFamily = Blocks.Mono, FontSize = 12 };
    private readonly TextBox reason = new() { FontSize = 13 };
    private readonly TextBox body = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 220, FontFamily = Blocks.Mono, FontSize = 12 };
    /// <summary>The body as the text box first showed it, to tell whether you changed it.</summary>
    private string shownBody = "";
    private readonly TextBlock footer = new() { VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };

    public PausedEditor(WirePaused paused, int othersWaiting, string subtitle, Func<JsonObject?, Task<string?>> decide)
    {
        this.paused = paused;
        this.decide = decide;
        var isRequest = paused.Part == "request";
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var top = new StackPanel { Padding = new Thickness(20, 14, 20, 10), Spacing = 10 };
        var banner = new Grid
        {
            ColumnSpacing = 10,
            Padding = new Thickness(12, 10, 12, 10),
            CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush((Windows.UI.Color)Application.Current.Resources["SystemAccentColor"]) { Opacity = 0.12 },
        };
        banner.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        banner.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        banner.Children.Add(new FontIcon { Glyph = "\uE769", FontSize = 16, Foreground = Blocks.Resource("AccentTextFillColorPrimaryBrush"), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) });
        var words = new StackPanel { Spacing = 2 };
        words.Children.Add(Blocks.Strong($"Paused by breakpoint “{paused.Breakpoint}”"));
        var more = othersWaiting switch { 0 => "", 1 => " 1 more is paused.", _ => $" {othersWaiting:N0} more are paused." };
        words.Children.Add(Blocks.Note($"The {paused.Part} is waiting. Edit it, then continue.{more}"));
        Grid.SetColumn(words, 1);
        banner.Children.Add(words);
        top.Children.Add(banner);
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        title.Children.Add(new TextBlock { Text = paused.Method, FontFamily = Blocks.Mono, FontSize = 12, Foreground = Blocks.Resource("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center });
        title.Children.Add(new TextBlock { Text = Uri.TryCreate(paused.Url, UriKind.Absolute, out var address) ? address.AbsolutePath : paused.Url, FontSize = 16, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        top.Children.Add(title);
        top.Children.Add(Blocks.Note(subtitle));
        root.Children.Add(top);

        var content = new StackPanel { Padding = new Thickness(20, 8, 20, 20), Spacing = 24 };
        if (isRequest)
        {
            var section = Blocks.Section("Request");
            var methods = CommonMethods.Contains(paused.Method) ? CommonMethods : [paused.Method, .. CommonMethods];
            foreach (var name in methods)
            {
                method.Items.Add(name);
            }
            method.SelectedItem = paused.Method;
            url.Text = paused.Url;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(url, "URL");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(method, "Method");
            var line = new Grid { ColumnSpacing = 8 };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetColumn(url, 1);
            line.Children.Add(method);
            line.Children.Add(url);
            section.Children.Add(line);
            content.Children.Add(section);
        }
        else
        {
            var section = Blocks.Section("Status");
            status.Text = paused.Status;
            reason.Text = paused.Reason;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(status, "Status");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(reason, "Reason");
            var line = new Grid { ColumnSpacing = 8 };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetColumn(reason, 1);
            line.Children.Add(status);
            line.Children.Add(reason);
            section.Children.Add(line);
            content.Children.Add(section);
        }

        var headersSection = new StackPanel();
        var heading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(0, 0, 0, 8) };
        heading.Children.Add(new TextBlock { Text = "Headers", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        heading.Children.Add(headerCount);
        headersSection.Children.Add(heading);
        headersSection.Children.Add(headerRows);
        foreach (var header in paused.Headers)
        {
            AddHeader(header.Name, header.Value, header);
        }
        var add = new Button { Content = "Add header", Margin = new Thickness(0, 8, 0, 0) };
        add.Click += (_, _) => AddHeader("", "", null).Focus(FocusState.Programmatic);
        headersSection.Children.Add(add);
        headersSection.Children.Add(new TextBlock
        {
            Text = "Reqly sets Content-Length from the body.",
            Margin = new Thickness(0, 6, 0, 0),
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            Foreground = Blocks.Resource("TextFillColorSecondaryBrush"),
        });
        content.Children.Add(headersSection);
        ShowHeaderCount();

        var bodySection = Blocks.Section("Body");
        if (paused.BinaryBodySize is int size)
        {
            bodySection.Children.Add(Blocks.Note($"This body isn't text: {(size == 1 ? "1 byte" : $"{size:N0} bytes")}. It goes on as it is."));
        }
        else
        {
            body.Text = paused.Body;
            shownBody = body.Text;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(body, "Body");
            bodySection.Children.Add(body);
        }
        content.Children.Add(bodySection);
        var scroller = new ScrollViewer { Content = content };
        Grid.SetRow(scroller, 1);
        root.Children.Add(scroller);

        var bar = new Grid
        {
            ColumnSpacing = 8,
            Padding = new Thickness(20, 10, 20, 12),
            BorderThickness = new Thickness(0, 1, 0, 0),
            BorderBrush = Blocks.Resource("DividerStrokeColorDefaultBrush"),
        };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ShowHint();
        bar.Children.Add(footer);
        var cancel = new Button { Content = isRequest ? "Cancel request" : "Cancel response" };
        cancel.Click += async (_, _) => await DecideAsync(cancels: true);
        Grid.SetColumn(cancel, 1);
        bar.Children.Add(cancel);
        var go = new Button { Content = "Continue", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        ToolTipService.SetToolTip(go, "Continue (Ctrl+Enter)");
        go.Click += async (_, _) => await DecideAsync(cancels: false);
        Grid.SetColumn(go, 2);
        bar.Children.Add(go);
        Grid.SetRow(bar, 2);
        root.Children.Add(bar);
        var shortcut = new KeyboardAccelerator { Key = VirtualKey.Enter, Modifiers = VirtualKeyModifiers.Control };
        shortcut.Invoked += async (sender, args) =>
        {
            args.Handled = true;
            await DecideAsync(cancels: false);
        };
        root.KeyboardAccelerators.Add(shortcut);
        Content = root;
    }

    public ulong Exchange => paused.Id;

    /// <summary>A header's row: its name and value, tinted once you change them, and a button that removes it.</summary>
    private TextBox AddHeader(string name, string value, WireHeader? original)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var nameBox = new TextBox { Text = name, PlaceholderText = "Name", FontFamily = Blocks.Mono, FontSize = 12 };
        var valueBox = new TextBox { Text = value, PlaceholderText = "Value", FontFamily = Blocks.Mono, FontSize = 12 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(nameBox, "Header name");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(valueBox, "Header value");
        var entry = (nameBox, valueBox, original);
        headers.Add(entry);
        void Tint()
        {
            var edited = original is null || original.Name != nameBox.Text || original.Value != valueBox.Text;
            var tint = edited ? new SolidColorBrush((Windows.UI.Color)Application.Current.Resources["SystemAccentColor"]) { Opacity = 0.10 } : null;
            nameBox.Background = tint;
            valueBox.Background = tint;
        }
        nameBox.TextChanged += (_, _) => Tint();
        valueBox.TextChanged += (_, _) => Tint();
        var remove = Blocks.IconButton("\uE738", "Remove header", () =>
        {
            headers.Remove(entry);
            headerRows.Children.Remove(row);
            ShowHeaderCount();
        });
        Grid.SetColumn(valueBox, 1);
        Grid.SetColumn(remove, 2);
        row.Children.Add(nameBox);
        row.Children.Add(valueBox);
        row.Children.Add(remove);
        headerRows.Children.Add(row);
        Tint();
        ShowHeaderCount();
        return nameBox;
    }

    private void ShowHeaderCount() => headerCount.Text = headers.Count.ToString("N0");

    private void ShowHint()
    {
        footer.Text = "Ctrl+Enter to continue";
        footer.Foreground = Blocks.Resource("TextFillColorSecondaryBrush");
    }

    /// <summary>Goes on with what you edited, or cancels it.</summary>
    private async Task DecideAsync(bool cancels)
    {
        if (cancels)
        {
            await decide(null);
            return;
        }
        var edit = new JsonObject
        {
            ["headers"] = new JsonArray(headers.Select(header => (JsonNode)new JsonObject
            {
                ["name"] = header.Name.Text,
                ["value"] = header.Value.Text,
                ["isSecret"] = false,
            }).ToArray()),
        };
        if (paused.Part == "request")
        {
            edit["method"] = method.SelectedItem as string ?? paused.Method;
            edit["url"] = url.Text;
        }
        else
        {
            edit["status"] = status.Text;
            edit["reason"] = reason.Text;
        }
        // A body you didn't change goes on byte for byte.
        if (paused.BinaryBodySize is null && body.Text != shownBody)
        {
            edit["body"] = Blocks.LinesAsIn(body.Text, paused.Body);
        }
        if (await decide(edit) is { } problem)
        {
            footer.Text = problem;
            footer.Foreground = Blocks.Resource("SystemFillColorCriticalBrush");
        }
    }

    /// <summary>Changes the URL and continues, as editing and pressing Continue would, for the self-check.</summary>
    public async Task ContinueWithUrlAsync(string address)
    {
        url.Text = address;
        await DecideAsync(cancels: false);
    }

    /// <summary>What the editor shows, for the self-check.</summary>
    public string Describe() => $"{paused.Part} at “{paused.Breakpoint}” · {paused.Method} {paused.Url} · {headers.Count} headers · {footer.Text}";
}
