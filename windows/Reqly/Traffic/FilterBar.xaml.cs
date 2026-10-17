using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Reqly.Core;

namespace Reqly.Traffic;

/// <summary>
/// The bar above the request list, as on the Mac: chips for the kinds of status, a token for
/// each other filter that's set, and the Filters button for the app, device, host, method and
/// content type. The core does the filtering.
/// </summary>
public sealed partial class FilterBar : UserControl
{
    /// <summary>The status chips, by the core's names, in order.</summary>
    private static readonly (string Name, string Title, string Tip)[] Statuses =
    [
        ("success", "2xx", "Show successful responses (2xx)"),
        ("redirection", "3xx", "Show redirects (3xx)"),
        ("clientError", "4xx", "Show client errors (4xx)"),
        ("serverError", "5xx", "Show server errors (5xx)"),
        ("failed", "Failed", "Show requests that failed"),
    ];

    /// <summary>The kinds of content, by the core's names, in the Mac's order.</summary>
    private static readonly (string Name, string Title)[] Contents =
    [
        ("json", "JSON"), ("xml", "XML"), ("html", "HTML"), ("javascript", "JavaScript"),
        ("css", "CSS"), ("image", "Images"), ("media", "Media"), ("other", "Other"),
    ];

    private readonly HashSet<string> statuses = [];
    private readonly HashSet<string> contents = [];
    private WireSource? source;
    /// <summary>This PC, as "", or a device by its ID.</summary>
    private string? device;
    private string? host;
    private string? method;

    private CoreSession? session;
    private WireSidebar? sidebar;
    private readonly ToggleButton allChip;
    private readonly Dictionary<string, ToggleButton> statusChips = [];
    private readonly Dictionary<string, FrameworkElement> statusIcons = [];
    private readonly Dictionary<string, CheckBox> contentBoxes = [];
    private bool isShowing;

    /// <summary>The filter changed, after the core has it.</summary>
    public event Action? Changed;

    /// <summary>How many requests the list shows, for the Filters flyout.</summary>
    public Func<int>? ShownCount { get; set; }

    public FilterBar()
    {
        InitializeComponent();
        allChip = Chip("All", "Show every status", null);
        allChip.Click += async (_, _) =>
        {
            statuses.Clear();
            await ApplyAsync();
        };
        Chips.Children.Add(allChip);
        foreach (var (name, title, tip) in Statuses)
        {
            var icon = StatusIcon(name);
            statusIcons[name] = icon;
            var chip = Chip(title, tip, icon);
            chip.Click += async (_, _) =>
            {
                if (!statuses.Remove(name))
                {
                    statuses.Add(name);
                }
                await ApplyAsync();
            };
            statusChips[name] = chip;
            Chips.Children.Add(chip);
        }
        for (var index = 0; index < Contents.Length; index++)
        {
            var (name, title) = Contents[index];
            var box = new CheckBox { Content = title, MinWidth = 0 };
            box.Click += async (_, _) =>
            {
                if (box.IsChecked == true)
                {
                    contents.Add(name);
                }
                else
                {
                    contents.Remove(name);
                }
                await ApplyAsync();
            };
            Grid.SetColumn(box, index % 2);
            Grid.SetRow(box, index / 2);
            contentBoxes[name] = box;
            ContentChoices.Children.Add(box);
        }
        for (var row = 0; row < (Contents.Length + 1) / 2; row++)
        {
            ContentChoices.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        }
        Show();
    }

    public void Attach(CoreSession session) => this.session = session;

    /// <summary>Whether any filter is set, status chips included.</summary>
    public bool IsActive =>
        statuses.Count > 0 || contents.Count > 0 || source is not null || device is not null || host is not null
        || method is not null;

    /// <summary>The apps, devices, hosts and methods the session has, for the menus.</summary>
    public void UseChoices(WireSidebar sidebar)
    {
        this.sidebar = sidebar;
        if (FiltersFlyout.IsOpen)
        {
            ShowChoices();
        }
    }

    /// <summary>Shows only these kinds of status, as turning their chips on does.</summary>
    public async Task SetStatusesAsync(IEnumerable<string> names)
    {
        statuses.Clear();
        statuses.UnionWith(names);
        await ApplyAsync();
    }

    /// <summary>Takes every filter off, status chips included, as Clear All does.</summary>
    public async Task ClearAsync()
    {
        statuses.Clear();
        contents.Clear();
        source = null;
        device = null;
        host = null;
        method = null;
        await ApplyAsync();
    }

    private async Task ApplyAsync()
    {
        Show();
        if (session is null)
        {
            return;
        }
        var filter = new JsonObject
        {
            ["statuses"] = new JsonArray(statuses.Select(name => (JsonNode)name).ToArray()),
            ["contents"] = new JsonArray(contents.Select(name => (JsonNode)name).ToArray()),
        };
        if (host is not null)
        {
            filter["host"] = host;
        }
        if (method is not null)
        {
            filter["method"] = method;
        }
        if (source is not null)
        {
            filter["source"] = JsonSerializer.SerializeToNode(source, Wire.Options);
        }
        if (device is not null)
        {
            filter["device"] = device;
        }
        try
        {
            await session.CallAsync(new JsonObject { ["call"] = "setFilter", ["filter"] = filter });
        }
        catch (CoreProblem problem)
        {
            AppLog.Write($"couldn't filter: {problem.Message}");
        }
        Changed?.Invoke();
    }

    // MARK: Showing the filters

    private void Show()
    {
        isShowing = true;
        allChip.IsChecked = statuses.Count == 0;
        foreach (var (name, chip) in statusChips)
        {
            chip.IsChecked = statuses.Contains(name);
        }
        foreach (var (name, box) in contentBoxes)
        {
            box.IsChecked = contents.Contains(name);
        }
        ShowTokens();
        ClearAllButton.IsEnabled = IsActive;
        isShowing = false;
    }

    /// <summary>A token for each filter set in the flyout, or one for them all when there are many.</summary>
    private void ShowTokens()
    {
        Tokens.Children.Clear();
        var chosen = new List<(string Kind, string Title, Action Clear)>();
        if (source is not null)
        {
            chosen.Add(("App", source.Name, () => source = null));
        }
        if (device is not null)
        {
            chosen.Add(("Device", DeviceName(device), () => device = null));
        }
        if (host is not null)
        {
            chosen.Add(("Host", host, () => host = null));
        }
        if (method is not null)
        {
            chosen.Add(("Method", method, () => method = null));
        }
        if (contents.Count > 0)
        {
            var titles = Contents.Where(content => contents.Contains(content.Name)).Select(content => content.Title).ToList();
            var title = titles.Count == 1 ? titles[0] : string.Join(", ", titles[..^1]) + " or " + titles[^1];
            chosen.Add(("Content type", title, contents.Clear));
        }
        if (chosen.Count > 3)
        {
            Tokens.Children.Add(Token(
                $"{chosen.Count} filters", "Filters",
                string.Join("\n", chosen.Select(choice => $"{choice.Kind}: {choice.Title}")),
                () => chosen.ForEach(choice => choice.Clear())));
            return;
        }
        foreach (var choice in chosen)
        {
            Tokens.Children.Add(Token(choice.Title, choice.Kind, $"{choice.Kind}: {choice.Title}", choice.Clear));
        }
    }

    private FrameworkElement Token(string title, string kind, string tip, Action clear)
    {
        var remove = new Button
        {
            Content = new FontIcon { Glyph = "\uE711", FontSize = 10 },
            Padding = new Thickness(5),
            MinWidth = 0,
            MinHeight = 0,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(remove, $"Remove {kind} filter");
        ToolTipService.SetToolTip(remove, "Remove this filter");
        remove.Click += async (_, _) =>
        {
            clear();
            await ApplyAsync();
        };
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        content.Children.Add(new TextBlock
        {
            Text = title,
            VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 220,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        content.Children.Add(remove);
        var token = new Border
        {
            Child = content,
            CornerRadius = new CornerRadius(13),
            Padding = new Thickness(11, 0, 3, 0),
            MinHeight = 26,
            // The accent, faintly, as the Mac's tokens are tinted.
            Background = new SolidColorBrush((Windows.UI.Color)Application.Current.Resources["SystemAccentColor"]) { Opacity = 0.18 },
        };
        ToolTipService.SetToolTip(token, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(token, $"{kind}: {title}");
        return token;
    }

    // MARK: The Filters flyout

    private void OnFiltersOpening(object sender, object e) => ShowChoices();

    /// <summary>Fills the menus: what the session has, plus the current choice, so it still shows after its traffic is cleared.</summary>
    private void ShowChoices()
    {
        isShowing = true;
        var sources = sidebar?.Sources ?? [];
        Fill(AppChoice, "Any app", Keep(sources, source).Select(app => (app.Name, (object)app)), source);
        var devices = sidebar?.Devices ?? [];
        var deviceChoices = devices.Select(row => (row.Name ?? "This PC", (object)row.Id)).ToList();
        if (device is not null && deviceChoices.All(choice => (string)choice.Item2 != device))
        {
            deviceChoices.Add((DeviceName(device), device));
        }
        var showsDevices = devices.Length > 0 || device is not null;
        DeviceLabel.Visibility = showsDevices ? Visibility.Visible : Visibility.Collapsed;
        DeviceChoice.Visibility = DeviceLabel.Visibility;
        Fill(DeviceChoice, "Any device", deviceChoices, device);
        var hosts = (sidebar?.Hosts ?? []).Select(row => row.Name).ToList();
        Fill(HostChoice, "Any host", Keep(hosts, host).Select(name => (name, (object)name)), host);
        var methods = sidebar?.Methods ?? [];
        Fill(MethodChoice, "Any method", Keep(methods, method).Select(name => (name, (object)name)), method);
        ShownText.Text = Format.Requests(ShownCount?.Invoke() ?? 0);
        isShowing = false;
    }

    private static IEnumerable<T> Keep<T>(IEnumerable<T> available, T? chosen)
    {
        var list = available.ToList();
        if (chosen is not null && !list.Contains(chosen))
        {
            list.Add(chosen);
        }
        return list;
    }

    private static void Fill(ComboBox box, string any, IEnumerable<(string Title, object Value)> choices, object? chosen)
    {
        box.Items.Clear();
        box.Items.Add(new ComboBoxItem { Content = any, Tag = null });
        var selected = 0;
        foreach (var (title, value) in choices)
        {
            if (Equals(value, chosen))
            {
                selected = box.Items.Count;
            }
            box.Items.Add(new ComboBoxItem { Content = title, Tag = value });
        }
        box.SelectedIndex = selected;
    }

    private async void OnChoiceChanged(object sender, SelectionChangedEventArgs e)
    {
        if (isShowing || sender is not ComboBox { SelectedItem: ComboBoxItem item } box)
        {
            return;
        }
        var value = item.Tag;
        if (box == AppChoice)
        {
            source = value as WireSource;
        }
        else if (box == DeviceChoice)
        {
            device = value as string;
        }
        else if (box == HostChoice)
        {
            host = value as string;
        }
        else if (box == MethodChoice)
        {
            method = value as string;
        }
        await ApplyAsync();
        ShowChoices();
    }

    private async void OnClearAllClicked(object sender, RoutedEventArgs e)
    {
        await ClearAsync();
        ShowChoices();
    }

    private string DeviceName(string id) =>
        id.Length == 0
            ? "This PC"
            : sidebar?.Devices.FirstOrDefault(row => row.Id == id)?.Name ?? "Device";

    // MARK: Chips

    private ToggleButton Chip(string title, string tip, FrameworkElement? icon)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (icon is not null)
        {
            content.Children.Add(icon);
        }
        content.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center });
        var chip = new ToggleButton { Content = content, Style = (Style)Resources["ChipStyle"] };
        ToolTipService.SetToolTip(chip, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(chip, title);
        return chip;
    }

    /// <summary>Light or dark mode changed: the dots take the new mode's colors, as the list's do.</summary>
    public void UseTheme()
    {
        foreach (var (name, icon) in statusIcons)
        {
            switch (icon)
            {
                case Ellipse dot:
                    dot.Fill = Palette.Status(name);
                    break;
                case FontIcon sign:
                    sign.Foreground = Palette.Failure;
                    break;
            }
        }
    }

    /// <summary>The status's dot, or a warning sign for failures, as in the list.</summary>
    private static FrameworkElement StatusIcon(string status) => status == "failed"
        ? new FontIcon { Glyph = "\uE7BA", FontSize = 11, Foreground = Palette.Failure, VerticalAlignment = VerticalAlignment.Center }
        : new Ellipse { Width = 7, Height = 7, Fill = Palette.Status(status), VerticalAlignment = VerticalAlignment.Center };
}
