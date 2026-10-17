using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Reqly.Core;
using Reqly.Https;
using Reqly.Traffic;

namespace Reqly.Inspector;

/// <summary>
/// The selected request's details, as the Mac's detail pane shows them: a header with the path,
/// where it went and how it went, buttons to pin, mark and comment, and the tabs Overview,
/// Request, Response, Messages (for WebSocket), Raw and Timing.
/// </summary>
public sealed partial class InspectorView : UserControl
{
    private InspectorContext? context;
    private HttpsModel? https;
    private WireDetails? details;
    /// <summary>The tab you chose. It stays as you select other requests, and comes back for one that has it.</summary>
    private string chosenTab = "overview";
    /// <summary>Set while the pane picks a tab itself, so it isn't taken for your choice.</summary>
    private bool isPickingTab;
    /// <summary>Whether the Overview should start editing the comment, as Add Comment asks.</summary>
    private bool editsComment;
    /// <summary>Goes up with each request shown, so a slow load for an earlier one shows nothing.</summary>
    private int generation;

    public InspectorView()
    {
        InitializeComponent();
        Tabs.SelectedItem = OverviewItem;
        Scroller.SizeChanged += (_, _) => ViewerHeight = Math.Max(240, Scroller.ActualHeight - 120);
    }

    /// <summary>How tall a body viewer grows before it scrolls inside itself.</summary>
    private double ViewerHeight { get; set; } = 480;

    /// <summary>The request shown, if any.</summary>
    public ulong? Shown => details?.Id;

    /// <summary>What the header and the tab say, for the self-check.</summary>
    public string Describe() =>
        $"{MethodText.Text} {TitleText.Text} · {SubtitleText.Text} · {string.Join(" ", FactsLine.Children.Select(TextOf))} · tab {ShownTab}";

    /// <summary>The tab's words, as far as they go, for the self-check.</summary>
    public string ContentText(int limit = 600)
    {
        var text = string.Join(" | ", TabContent.Children.Where(Shows).Select(TextOf).Where(part => part.Length > 0));
        return text.Length > limit ? text[..limit] + "…" : text;
    }

    /// <summary>Only what shows counts, as hidden notes, such as one for no matches, say nothing.</summary>
    private static bool Shows(UIElement element) => element.Visibility == Visibility.Visible;

    private static string TextOf(UIElement element) => element switch
    {
        TextBlock block => block.Text,
        RichTextBlock rich => string.Concat(rich.Blocks.OfType<Microsoft.UI.Xaml.Documents.Paragraph>()
            .SelectMany(paragraph => paragraph.Inlines.OfType<Microsoft.UI.Xaml.Documents.Run>()).Select(run => run.Text)),
        TextBox box => box.Text,
        InfoBar bar => bar.Message,
        Panel panel => string.Join(" ", panel.Children.Where(Shows).Select(TextOf).Where(part => part.Length > 0)),
        Border border when border.Child is { } child => TextOf(child),
        ScrollViewer scroller when scroller.Content is UIElement inner => TextOf(inner),
        ContentControl control when control.Content is UIElement inner => TextOf(inner),
        UserControl control when control.Content is { } inner => TextOf(inner),
        _ => "",
    };

    /// <summary>The session to read details from, and HTTPS, for the live session only.</summary>
    public void Attach(InspectorContext context, HttpsModel? https)
    {
        this.context = context;
        this.https = https;
        if (https is null)
        {
            return;
        }
        https.Changed += () =>
        {
            if (details is not null && chosenTab == "overview")
            {
                _ = ShowTabAsync();
            }
        };
    }

    public void ShowNothing()
    {
        generation++;
        details = null;
        Details.Visibility = Visibility.Collapsed;
        Nothing.Visibility = Visibility.Visible;
    }

    /// <summary>Shows a request, or the same one again once it moved on.</summary>
    public async Task ShowAsync(ulong id)
    {
        if (context is null)
        {
            return;
        }
        var shown = ++generation;
        try
        {
            var loaded = Wire.Read<WireDetails>(await context.Session.CallAsync(new JsonObject { ["call"] = "details", ["id"] = id }));
            if (shown != generation)
            {
                return;
            }
            var isSame = details?.Id == id;
            details = loaded;
            Nothing.Visibility = Visibility.Collapsed;
            Details.Visibility = Visibility.Visible;
            ShowHeader(loaded);
            ShowTabs(loaded);
            await ShowTabAsync(keepsScroll: isSame);
        }
        catch (CoreProblem problem)
        {
            if (shown == generation)
            {
                TabContent.Children.Clear();
                TabContent.Children.Add(Blocks.Note(problem.Message));
            }
        }
    }

    /// <summary>Opens the Overview with the comment ready to type, as Add Comment does.</summary>
    public void EditComment()
    {
        editsComment = true;
        PickTab("overview");
        _ = ShowTabAsync();
    }

    /// <summary>Shows a tab, as its shortcut does, if the request has it.</summary>
    public void ShowTab(string tab)
    {
        if (details is null || (tab == "messages" && !details.IsWebSocket))
        {
            return;
        }
        chosenTab = tab;
        PickTab(tab);
        _ = ShowTabAsync();
    }

    // MARK: The header

    private void ShowHeader(WireDetails shown)
    {
        MethodText.Text = shown.Method;
        TitleText.Text = shown.IsTunnel ? DisplayHost(shown) : shown.Path;
        var destination = new List<string> { shown.IsTunnel ? "Encrypted connection" : DisplayHost(shown) };
        if (shown.App is { } app)
        {
            destination.Add(app);
        }
        if (shown.Device is { } device)
        {
            destination.Add(device);
        }
        SubtitleText.Text = string.Join(" · ", destination);
        ShowFacts(shown);
        ShowAnnotation(shown);
    }

    /// <summary>The host, with the port when it isn't the scheme's own.</summary>
    public static string DisplayHost(WireDetails shown) =>
        (shown.Scheme, shown.Port) is ("http", 80) or ("https", 443) ? shown.Host : $"{shown.Host}:{shown.Port}";

    /// <summary>The status, then gRPC's, the messages, the duration, the size received and when it started.</summary>
    private void ShowFacts(WireDetails shown)
    {
        FactsLine.Children.Clear();
        FactsLine.Children.Add(StatusLabel(shown));
        if (shown.Grpc is { } grpc)
        {
            var label = Caption($"gRPC {grpc.Name}");
            label.Foreground = grpc.Code == 0 ? Blocks.Resource("TextFillColorSecondaryBrush") : Blocks.Resource("TextFillColorPrimaryBrush");
            ToolTipService.SetToolTip(label, grpc.Message ?? grpc.Title);
            FactsLine.Children.Add(label);
        }
        if (shown.IsWebSocket)
        {
            FactsLine.Children.Add(Caption(shown.MessageCount == 1 ? "1 message" : $"{shown.MessageCount:N0} messages"));
        }
        if (shown.Ended is double ended)
        {
            FactsLine.Children.Add(Caption(Format.Duration(ended - shown.Started)));
        }
        FactsLine.Children.Add(Caption(Format.Size(shown.BytesReceived)));
        FactsLine.Children.Add(Caption(Format.Time(shown.Started)));
    }

    private static FrameworkElement StatusLabel(WireDetails shown)
    {
        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        switch (shown)
        {
            case { State: "failed" }:
                label.Children.Add(new FontIcon { Glyph = "\uE7BA", FontSize = 12, Foreground = Blocks.Resource("SystemFillColorCriticalBrush") });
                label.Children.Add(new TextBlock { Text = "Failed", FontSize = 12 });
                break;
            case { State: "paused" }:
                label.Children.Add(new FontIcon { Glyph = "\uE769", FontSize = 12, Foreground = Blocks.Resource("AccentTextFillColorPrimaryBrush") });
                label.Children.Add(new TextBlock { Text = "Paused", FontSize = 12 });
                break;
            case { Status: int status }:
                label.Children.Add(new Ellipse { Width = 7, Height = 7, Fill = Palette.Status(StatusClass(shown)), VerticalAlignment = VerticalAlignment.Center });
                label.Children.Add(new TextBlock { Text = status.ToString(), FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
                if (shown.Reason is { Length: > 0 } reason)
                {
                    label.Children.Add(Caption(reason));
                }
                break;
            case { Kind: "tunnel" }:
                label.Children.Add(new FontIcon { Glyph = "\uE72E", FontSize = 12, Foreground = Blocks.Resource("TextFillColorSecondaryBrush") });
                label.Children.Add(Caption(shown.State == "open" ? "Open" : "Closed"));
                break;
            default:
                label.Children.Add(Caption("In progress"));
                break;
        }
        return label;
    }

    /// <summary>The status's class, with a gRPC call's own status deciding when HTTP said 2xx.</summary>
    private static string? StatusClass(WireDetails shown)
    {
        if (shown.Grpc is { } grpc && shown.Status is >= 200 and < 300)
        {
            return grpc.Code switch
            {
                0 => "success",
                1 or 3 or 5 or 6 or 7 or 8 or 9 or 10 or 11 or 16 => "clientError",
                _ => "serverError",
            };
        }
        return shown.Status switch
        {
            >= 100 and < 200 => "informational",
            >= 200 and < 300 => "success",
            >= 300 and < 400 => "redirection",
            >= 400 and < 500 => "clientError",
            >= 500 and < 600 => "serverError",
            _ => null,
        };
    }

    private static TextBlock Caption(string text) => new()
    {
        Text = text,
        FontSize = 12,
        Foreground = Blocks.Resource("TextFillColorSecondaryBrush"),
        VerticalAlignment = VerticalAlignment.Center,
    };

    // MARK: Pins, marks and comments

    private void ShowAnnotation(WireDetails shown)
    {
        PinIcon.Glyph = shown.IsPinned ? "\uE840" : "\uE718";
        PinIcon.Foreground = shown.IsPinned ? Blocks.Resource("AccentTextFillColorPrimaryBrush") : Blocks.Resource("TextFillColorSecondaryBrush");
        var pinTip = shown.IsPinned ? "Unpin request" : "Pin request. Pinned requests stay when you clear traffic.";
        ToolTipService.SetToolTip(PinButton, pinTip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(PinButton, shown.IsPinned ? "Unpin request" : "Pin request");
        ColorDot.Fill = shown.Color is { } color ? Palette.Mark(color) : null;
        ColorDot.Stroke = shown.Color is null ? Blocks.Resource("TextFillColorSecondaryBrush") : null;
        var menu = new MenuFlyout();
        foreach (var choice in new string?[] { null }.Concat(Palette.MarkColors))
        {
            var item = new RadioMenuFlyoutItem
            {
                Text = choice is null ? "None" : Palette.MarkName(choice),
                GroupName = "Color",
                IsChecked = shown.Color == choice,
            };
            item.Click += (_, _) => _ = AnnotateAsync(new JsonObject { ["color"] = choice is null ? null : JsonValue.Create(choice) });
            menu.Items.Add(item);
            if (choice is null)
            {
                menu.Items.Add(new MenuFlyoutSeparator());
            }
        }
        ColorButton.Flyout = menu;
        CommentIcon.Foreground = shown.Comment is null ? Blocks.Resource("TextFillColorSecondaryBrush") : Blocks.Resource("AccentTextFillColorPrimaryBrush");
        var commentTip = shown.Comment is null ? "Add comment" : "Edit comment";
        ToolTipService.SetToolTip(CommentButton, commentTip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(CommentButton, commentTip);
    }

    private async void OnPinClicked(object sender, RoutedEventArgs e)
    {
        if (details is { } shown)
        {
            await AnnotateAsync(new JsonObject { ["isPinned"] = !shown.IsPinned });
        }
    }

    private void OnCommentClicked(object sender, RoutedEventArgs e) => EditComment();

    /// <summary>Changes the request's pin, mark or comment, then shows it as the core saved it.</summary>
    private async Task AnnotateAsync(JsonObject change)
    {
        if (context is null || details is not { } shown)
        {
            return;
        }
        change["call"] = "annotate";
        change["id"] = shown.Id;
        try
        {
            await context.Session.CallAsync(change);
            await ShowAsync(shown.Id);
        }
        catch (CoreProblem problem)
        {
            AppLog.Write($"couldn't annotate: {problem.Message}");
        }
    }

    // MARK: Tabs

    /// <summary>Messages shows only for WebSocket; the tab you chose comes back when a request has it.</summary>
    private void ShowTabs(WireDetails shown)
    {
        MessagesItem.Visibility = shown.IsWebSocket ? Visibility.Visible : Visibility.Collapsed;
        var tab = chosenTab == "messages" && !shown.IsWebSocket ? "overview" : chosenTab;
        PickTab(tab);
    }

    private void PickTab(string tab)
    {
        var item = Tabs.Items.FirstOrDefault(each => (string)each.Tag == tab) ?? OverviewItem;
        if (!ReferenceEquals(Tabs.SelectedItem, item))
        {
            isPickingTab = true;
            Tabs.SelectedItem = item;
            isPickingTab = false;
        }
    }

    private string ShownTab => (string?)Tabs.SelectedItem?.Tag ?? "overview";

    private void OnTabChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        if (isPickingTab || details is null)
        {
            return;
        }
        chosenTab = ShownTab;
        _ = ShowTabAsync();
    }

    private async Task ShowTabAsync(bool keepsScroll = false)
    {
        if (details is not { } shown || context is null)
        {
            return;
        }
        var shownGeneration = generation;
        var offset = Scroller.VerticalOffset;
        var parts = ShownTab switch
        {
            "request" => await RequestTabAsync(shown),
            "response" => await ResponseTabAsync(shown),
            "messages" => await MessagesTabAsync(shown),
            "raw" => await RawTabAsync(shown),
            "timing" => TimingParts(shown),
            _ => await OverviewTabAsync(shown),
        };
        if (shownGeneration != generation)
        {
            return;
        }
        TabContent.Children.Clear();
        foreach (var part in parts)
        {
            TabContent.Children.Add(part);
        }
        if (keepsScroll)
        {
            Scroller.ChangeView(null, offset, null, disableAnimation: true);
        }
        else
        {
            Scroller.ChangeView(null, 0, null, disableAnimation: true);
        }
    }
}
