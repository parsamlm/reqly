using System.Collections.ObjectModel;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Reqly.Core;

namespace Reqly.Traffic;

/// <summary>
/// The sidebar, as the Mac app's: All Traffic, Pinned once something is pinned, this PC's apps
/// (or each device with its apps and hosts, once a device sends traffic), then the hosts, each
/// with its count. Choosing one narrows the list to it. The rows come from the core's "sidebar"
/// event, and their counts from "counts".
/// </summary>
public sealed class Sidebar
{
    private const string AllKey = "all";
    private const string PinnedKey = "pinned";

    private readonly CoreSession session;
    private readonly NavigationView view;
    /// <summary>The pane's items, in order: rows and section headers.</summary>
    private readonly ObservableCollection<object> items = [];
    /// <summary>Each row, by its key, kept while the row shows so its selection stays.</summary>
    private readonly Dictionary<string, Row> rows = [];
    private readonly Row all;
    private readonly Row pinned;
    private readonly NavigationViewItemHeader appsHeader = Header("Apps");
    private readonly NavigationViewItemHeader devicesHeader = Header("Devices");
    private readonly NavigationViewItemHeader hostsHeader = Header("Hosts");
    private readonly NavigationViewItemHeader noHosts = Hint("Hosts show up here as apps talk to them.");
    /// <summary>The devices whose apps and hosts are folded away.</summary>
    private readonly HashSet<string> collapsed = [];
    /// <summary>The rows as the latest "sidebar" event named them. Their counts may be older than <see cref="counts"/>.</summary>
    private WireSidebar? latest;
    /// <summary>Each row's latest count, by key, from "sidebar" and "counts" events alike.</summary>
    private readonly Dictionary<string, int> counts = [];
    private bool isShowing;

    /// <summary>How many exchanges the session has.</summary>
    public int Total { get; private set; }
    /// <summary>How many of them are pinned.</summary>
    public int Pinned { get; private set; }

    /// <summary>The row the list is narrowed to.</summary>
    public string SelectedKey { get; private set; } = AllKey;
    /// <summary>What the list shows, such as "All Traffic", a host, or an app on a device, for the heading.</summary>
    public string SelectedHeading => rows.TryGetValue(SelectedKey, out var row) ? row.Heading : selectedHeading;

    /// <summary>How many requests the selected row covers, before filters and the search.</summary>
    public int SelectedCount => rows.TryGetValue(SelectedKey, out var row) ? row.CountValue : 0;

    private string selectedHeading = "All Traffic";

    /// <summary>The list was narrowed to another row.</summary>
    public event Action? ScopeChanged;

    /// <summary>Renames a device, by its ID and the name it shows with, in the window for the traffic being captured.</summary>
    public Func<string, string, Task>? RenameDevice { get; set; }

    public Sidebar(CoreSession session, NavigationView view)
    {
        this.session = session;
        this.view = view;
        all = new Row(AllKey, "All Traffic", Glyph("\uE8AB"));
        pinned = new Row(PinnedKey, "Pinned", Glyph("\uE718"));
        var unpinAll = new MenuFlyoutItem { Text = "Unpin all requests" };
        unpinAll.Click += async (_, _) => await CallAsync(new JsonObject { ["call"] = "unpinAll" });
        pinned.Item.ContextFlyout = new MenuFlyout { Items = { unpinAll } };
        pinned.Item.ContextFlyout.Opening += (_, _) => unpinAll.IsEnabled = Pinned > 0;
        rows[AllKey] = all;
        view.MenuItemsSource = items;
        items.Add(all.Item);
        items.Add(appsHeader);
        view.SelectedItem = all.Item;
        view.SelectionChanged += OnSelectionChanged;
        view.Expanding += (_, args) => SetCollapsed(args.ExpandingItem, false);
        view.Collapsed += (_, args) => SetCollapsed(args.CollapsedItem, true);
        latest = new WireSidebar(0, 0, [], [], [], [], []);
        Layout();
    }

    /// <summary>A row's latest count.</summary>
    public int CountOf(string key) => key switch
    {
        AllKey => Total,
        PinnedKey => Pinned,
        _ => counts.GetValueOrDefault(key),
    };

    /// <summary>Narrows the list to a row, as choosing it does.</summary>
    public void Select(string key)
    {
        if (rows.TryGetValue(key, out var row))
        {
            view.SelectedItem = row.Item;
        }
    }

    /// <summary>The methods and apps the session's requests have, for the filters.</summary>
    public WireSidebar? Latest => latest;

    /// <summary>The pane's rows as they show, each device's own in brackets, and the selected one, for the self-check.</summary>
    public string Describe()
    {
        static string Name(object item) => (item as NavigationViewItem)?.Tag is Row row ? row.Name : "?";
        var shown = items.Select(item => item switch
        {
            NavigationViewItemHeader header => $"{header.Content}:",
            NavigationViewItem { MenuItems.Count: > 0 } parent => $"{Name(parent)} [{string.Join(", ", parent.MenuItems.Select(Name))}]",
            _ => Name(item),
        });
        return $"{string.Join(" ", shown)} · selected {(view.SelectedItem is { } selected ? Name(selected) : "nothing")}";
    }

    public void Apply(JsonElement update)
    {
        switch (update.GetProperty("event").GetString())
        {
            case "sidebar":
                var sidebar = Wire.Read<WireSidebar>(update);
                latest = sidebar;
                counts.Clear();
                foreach (var row in sidebar.Apps.Concat(sidebar.Hosts)
                    .Concat(sidebar.Devices.SelectMany(device => device.Apps.Concat(device.OtherHosts))))
                {
                    counts[row.Key] = row.Count;
                }
                foreach (var device in sidebar.Devices)
                {
                    counts[device.Key] = device.Count;
                }
                Total = sidebar.Total;
                Pinned = sidebar.Pinned;
                Layout();
                break;
            case "counts":
                Total = update.GetProperty("total").GetInt32();
                var wasPinned = Pinned > 0;
                Pinned = update.GetProperty("pinned").GetInt32();
                foreach (var count in update.GetProperty("counts").EnumerateObject())
                {
                    counts[count.Name] = count.Value.GetInt32();
                    if (rows.TryGetValue(count.Name, out var row))
                    {
                        row.Count = count.Value.GetInt32();
                    }
                }
                all.Count = Total;
                pinned.Count = Pinned;
                if (wasPinned != Pinned > 0)
                {
                    // Pinned shows once something is pinned.
                    Layout();
                }
                break;
        }
    }

    /// <summary>
    /// Lays the rows out again from the latest names, with the latest counts, keeping the rows that
    /// stay, so the selection stays too.
    /// </summary>
    private void Layout()
    {
        var sidebar = latest!;
        var shown = new List<object> { all.Item };
        var keys = new HashSet<string> { AllKey };
        all.Count = Total;
        isShowing = true;
        if (Pinned > 0 || SelectedKey == PinnedKey)
        {
            pinned.Count = Pinned;
            shown.Add(pinned.Item);
            keys.Add(PinnedKey);
            rows[PinnedKey] = pinned;
        }
        if (sidebar.Devices.Length == 0)
        {
            // All of it came from this PC.
            if (sidebar.Apps.Length > 0)
            {
                shown.Add(appsHeader);
                foreach (var app in sidebar.Apps)
                {
                    shown.Add(AppRow(app, keys).Item);
                }
            }
        }
        else
        {
            // A phone, a simulator or an emulator sent some: this PC and each device show with
            // their own apps, then the hosts of traffic no app is known for.
            shown.Add(devicesHeader);
            foreach (var device in sidebar.Devices)
            {
                var deviceName = device.Name ?? "This PC";
                var row = RowFor(device.Key, deviceName, () => Glyph(DeviceGlyph(device.Kind)), keys);
                row.Count = counts.GetValueOrDefault(device.Key, device.Count);
                if (RenameDevice is { } rename && device.Id.Length > 0)
                {
                    var item = new MenuFlyoutItem { Text = "Rename…" };
                    var id = device.Id;
                    item.Click += async (_, _) => await rename(id, deviceName);
                    row.Item.ContextFlyout = new MenuFlyout { Items = { item } };
                }
                var apps = device.Apps.Select(app => AppRow(app, keys, row)).ToList();
                var hosts = device.OtherHosts.Select(host => HostRow(host, keys, row)).ToList();
                foreach (var child in apps.Concat(hosts))
                {
                    child.Heading = $"{child.Name} on {deviceName}";
                }
                var children = apps.Select(child => child.Item).Concat(hosts.Select(child => child.Item)).ToList<object>();
                Patch(row.Item.MenuItems, children);
                row.Item.IsExpanded = children.Count > 0 && !collapsed.Contains(device.Key);
                shown.Add(row.Item);
            }
        }
        shown.Add(hostsHeader);
        if (sidebar.Hosts.Length == 0)
        {
            shown.Add(noHosts);
        }
        foreach (var host in sidebar.Hosts)
        {
            shown.Add(HostRow(host, keys).Item);
        }
        foreach (var gone in rows.Keys.Where(key => !keys.Contains(key)).ToList())
        {
            rows.Remove(gone);
        }
        Patch(items, shown);
        // The selected row may have gone, for a while, and come back.
        if (rows.TryGetValue(SelectedKey, out var selected) && !ReferenceEquals(view.SelectedItem, selected.Item))
        {
            view.SelectedItem = selected.Item;
        }
        isShowing = false;
    }

    private Row AppRow(WireSidebarRow app, HashSet<string> keys, Row? device = null)
    {
        var row = RowFor(app.Key, app.Name, () => Glyph("\uE737"), keys, device);
        row.Count = counts.GetValueOrDefault(app.Key, app.Count);
        if (app.Path is { } program && !row.HasIcon)
        {
            row.HasIcon = true;
            _ = ShowIconAsync(row, program);
        }
        return row;
    }

    private static async Task ShowIconAsync(Row row, string program)
    {
        if (await AppIcons.GetAsync(program) is { } icon)
        {
            row.Item.Icon = new ImageIcon { Source = icon, Width = 16, Height = 16 };
        }
    }

    private Row HostRow(WireSidebarRow host, HashSet<string> keys, Row? device = null)
    {
        var row = RowFor(host.Key, host.Name, () => Glyph("\uE774"), keys, device);
        row.Count = counts.GetValueOrDefault(host.Key, host.Count);
        return row;
    }

    /// <summary>
    /// A key's row, under a device's row or, with none, at the top. A row that moves between the
    /// two, as this PC's apps do when a device's traffic comes or goes, is made again: WinUI lets
    /// an item have only one parent, and the one it leaves may keep it.
    /// </summary>
    private Row RowFor(string key, string name, Func<IconElement> icon, HashSet<string> keys, Row? device = null)
    {
        keys.Add(key);
        if (!rows.TryGetValue(key, out var row) || !ReferenceEquals(row.Device, device))
        {
            row = new Row(key, name, icon()) { Device = device };
            rows[key] = row;
        }
        row.Name = name;
        return row;
    }

    /// <summary>Changes a collection into another with as few moves as it takes, keeping the items both share.</summary>
    private static void Patch(IList<object> current, IReadOnlyList<object> target)
    {
        for (var index = 0; index < target.Count; index++)
        {
            if (index < current.Count && ReferenceEquals(current[index], target[index]))
            {
                continue;
            }
            var at = -1;
            for (var later = index + 1; later < current.Count; later++)
            {
                if (ReferenceEquals(current[later], target[index]))
                {
                    at = later;
                    break;
                }
            }
            if (at >= 0)
            {
                if (current is ObservableCollection<object> observable)
                {
                    observable.Move(at, index);
                }
                else
                {
                    var item = current[at];
                    current.RemoveAt(at);
                    current.Insert(index, item);
                }
            }
            else
            {
                current.Insert(index, target[index]);
            }
        }
        while (current.Count > target.Count)
        {
            current.RemoveAt(current.Count - 1);
        }
    }

    private async void OnSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (isShowing || args.SelectedItem is not NavigationViewItem { Tag: Row row } || row.Key == SelectedKey)
        {
            return;
        }
        SelectedKey = row.Key;
        selectedHeading = row.Heading;
        ScopeChanged?.Invoke();
        await CallAsync(new JsonObject { ["call"] = "setScope", ["key"] = row.Key });
        if (row.Key != PinnedKey && Pinned == 0)
        {
            // Pinned shows only while something is pinned, or while it's selected.
            Layout();
        }
    }

    private void SetCollapsed(object item, bool isCollapsed)
    {
        if (item is NavigationViewItem { Tag: Row row })
        {
            if (isCollapsed)
            {
                collapsed.Add(row.Key);
            }
            else
            {
                collapsed.Remove(row.Key);
            }
        }
    }

    private async Task CallAsync(JsonObject request)
    {
        try
        {
            await session.CallAsync(request);
        }
        catch (CoreProblem problem)
        {
            AppLog.Write($"sidebar: {problem.Code}: {problem.Message}");
        }
    }

    private static string DeviceGlyph(string? kind) => kind switch
    {
        null => "\uE7F8",
        "network" => "\uE8EA",
        _ => "\uE8CC",
    };

    private static FontIcon Glyph(string glyph) => new() { Glyph = glyph };

    private static NavigationViewItemHeader Header(string title) => new() { Content = title };

    private static NavigationViewItemHeader Hint(string text) => new()
    {
        Content = new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        },
    };

    /// <summary>A row of the pane: its item, with the name on the left and the count on the right.</summary>
    private sealed class Row
    {
        private readonly TextBlock name;
        private readonly TextBlock count;

        public string Key { get; }
        public NavigationViewItem Item { get; }
        public bool HasIcon { get; set; }
        /// <summary>The device's row it shows under, or none at the top.</summary>
        public Row? Device { get; init; }

        public Row(string key, string title, IconElement icon)
        {
            Key = key;
            name = new TextBlock { Text = title, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
            count = new TextBlock
            {
                Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(8, 0, 0, 0),
            };
            var content = new Grid();
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn(count, 1);
            content.Children.Add(name);
            content.Children.Add(count);
            Item = new NavigationViewItem { Content = content, Icon = icon, Tag = this };
            Heading = title;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(Item, title);
            ToolTipService.SetToolTip(Item, title);
        }

        public string Name
        {
            get => name.Text;
            set
            {
                if (name.Text != value)
                {
                    name.Text = value;
                    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(Item, value);
                    ToolTipService.SetToolTip(Item, value);
                }
                Heading = value;
            }
        }

        /// <summary>What the window's heading says while the row is selected.</summary>
        public string Heading { get; set; } = "";

        public int CountValue { get; private set; }

        public int Count
        {
            set
            {
                CountValue = value;
                // As the Mac's badges, a count of none shows nothing.
                count.Text = value == 0 ? "" : value.ToString("N0");
            }
        }
    }
}
