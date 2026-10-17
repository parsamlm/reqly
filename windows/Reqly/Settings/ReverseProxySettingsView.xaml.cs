using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Shapes;
using Reqly.Core;
using Reqly.Inspector;
using Windows.System;

namespace Reqly.Settings;

/// <summary>
/// The Reverse Proxy page of Settings, as the Mac's: local addresses that send every request on
/// to one server, for apps that can't use a proxy. Each says whether it's listening.
/// </summary>
public sealed partial class ReverseProxySettingsView : UserControl
{
    private readonly ConnectionsModel connections;
    private readonly Func<bool> isCapturing;
    private ContentDialog? editor;

    public ReverseProxySettingsView(ConnectionsModel connections, Func<bool> isCapturing)
    {
        this.connections = connections;
        this.isCapturing = isCapturing;
        InitializeComponent();
        Loaded += async (_, _) =>
        {
            connections.Changed += Show;
            Show();
            // Whether each is listening changes as capturing starts and stops.
            await connections.RefreshAsync();
        };
        Unloaded += (_, _) => connections.Changed -= Show;
    }

    private WireReverseProxyRow? Selected => (ProxyList.SelectedItem as ListViewItem)?.Tag as WireReverseProxyRow;

    /// <summary>What the page shows, for the self-check.</summary>
    public string Describe() => string.Join(", ", connections.Connections.ReverseProxies.Select(proxy => $"{proxy.LocalAddress} → {proxy.Server} ({Status(proxy).Text})"));

    private void Show()
    {
        var selected = Selected?.Id;
        ProxyList.Items.Clear();
        foreach (var proxy in connections.Connections.ReverseProxies)
        {
            var item = new ListViewItem { Content = Row(proxy), Tag = proxy };
            ProxyList.Items.Add(item);
            if (proxy.Id == selected)
            {
                ProxyList.SelectedItem = item;
            }
        }
        var isEmpty = connections.Connections.ReverseProxies.Length == 0;
        NoProxies.Visibility = isEmpty ? Visibility.Visible : Visibility.Collapsed;
        ProxyList.Visibility = isEmpty ? Visibility.Collapsed : Visibility.Visible;
        ShowButtons();
    }

    private void ShowButtons()
    {
        RemoveButton.IsEnabled = Selected is not null;
        EditButton.IsEnabled = Selected is not null;
    }

    /// <summary>A reverse proxy: its switch, its address and its server, and whether it's listening.</summary>
    private Grid Row(WireReverseProxyRow proxy)
    {
        var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 6, 0, 6), Opacity = proxy.IsOn ? 1 : 0.6 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var toggle = new ToggleSwitch { IsOn = proxy.IsOn, OnContent = "", OffContent = "", MinWidth = 0, Width = 44, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(toggle, "Use this reverse proxy");
        toggle.Toggled += (_, _) =>
        {
            if (toggle.IsOn != proxy.IsOn)
            {
                _ = connections.SetReverseProxyOnAsync(proxy.Id, toggle.IsOn);
            }
        };
        var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        line.Children.Add(new TextBlock { Text = proxy.LocalAddress, FontFamily = Blocks.Mono });
        var arrow = new FontIcon { Glyph = "", FontSize = 11, Foreground = Blocks.Resource("TextFillColorSecondaryBrush") };
        AutomationProperties.SetName(arrow, "to");
        line.Children.Add(arrow);
        line.Children.Add(new TextBlock { Text = proxy.Server, FontFamily = Blocks.Mono, TextTrimming = TextTrimming.CharacterEllipsis });
        words.Children.Add(line);
        words.Children.Add(Status(proxy).View);
        Grid.SetColumn(words, 1);
        row.Children.Add(toggle);
        row.Children.Add(words);
        return row;
    }

    /// <summary>Off, why it isn't listening, listening, or that it will once capturing starts.</summary>
    private (UIElement View, string Text) Status(WireReverseProxyRow proxy)
    {
        if (!proxy.IsOn)
        {
            return (Caption("Off"), "Off");
        }
        if (proxy.Problem is { } problem)
        {
            var failure = Blocks.Failure(problem);
            return (failure, problem);
        }
        if (isCapturing())
        {
            var listening = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            listening.Children.Add(new Ellipse { Width = 6, Height = 6, Fill = Traffic.Palette.Status("success"), VerticalAlignment = VerticalAlignment.Center });
            listening.Children.Add(Caption("Listening"));
            return (listening, "Listening");
        }
        return (Caption("Listens once you start capturing"), "Listens once you start capturing");
    }

    private static TextBlock Caption(string text) => new()
    {
        Text = text,
        Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        Foreground = Blocks.Resource("TextFillColorSecondaryBrush"),
    };

    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e) => ShowButtons();

    private async void OnAddClicked(object sender, RoutedEventArgs e)
    {
        try
        {
            await EditAsync(await connections.NewReverseProxyAsync(), isNew: true);
        }
        catch (CoreProblem problem)
        {
            AppLog.Write($"couldn't start a reverse proxy: {problem.Message}");
        }
    }

    private async void OnEditClicked(object sender, RoutedEventArgs e)
    {
        if (Selected is { } proxy)
        {
            await EditAsync(ConnectionsModel.Edit(proxy), isNew: false);
        }
    }

    private void OnRemoveClicked(object sender, RoutedEventArgs e) => Remove(Selected);

    private void Remove(WireReverseProxyRow? proxy)
    {
        if (proxy is not null)
        {
            _ = connections.RemoveReverseProxyAsync(proxy.Id);
        }
    }

    private async void OnListDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (Selected is { } proxy)
        {
            await EditAsync(ConnectionsModel.Edit(proxy), isNew: false);
        }
    }

    private void OnListKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Delete)
        {
            e.Handled = true;
            Remove(Selected);
        }
    }

    private void OnContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        var item = (args.OriginalSource as DependencyObject) is { } source ? ItemOf(source) : null;
        if (item?.Tag is not WireReverseProxyRow proxy)
        {
            return;
        }
        args.Handled = true;
        ProxyList.SelectedItem = item;
        var menu = new MenuFlyout();
        var edit = new MenuFlyoutItem { Text = "Edit…" };
        edit.Click += async (_, _) => await EditAsync(ConnectionsModel.Edit(proxy), isNew: false);
        var remove = new MenuFlyoutItem { Text = "Remove" };
        remove.Click += (_, _) => Remove(proxy);
        menu.Items.Add(edit);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(remove);
        if (args.TryGetPosition(ProxyList, out var point))
        {
            menu.ShowAt(ProxyList, point);
        }
        else
        {
            menu.ShowAt(item);
        }
    }

    private static ListViewItem? ItemOf(DependencyObject source)
    {
        for (var element = source; element is not null; element = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(element))
        {
            if (element is ListViewItem item)
            {
                return item;
            }
        }
        return null;
    }

    /// <summary>The editor for a reverse proxy: its port, its server, and whether redirects stay on it.</summary>
    public async Task EditAsync(WireReverseProxy proxy, bool isNew)
    {
        if (editor is not null || XamlRoot is null)
        {
            return;
        }
        var port = new TextBox { Header = "Local port", PlaceholderText = "8080", Text = proxy.Port, InputScope = new InputScope { Names = { new InputScopeName(InputScopeNameValue.Number) } } };
        var server = new TextBox { Header = Blocks.FieldHeader("Server"), PlaceholderText = "https://api.example.com", Text = proxy.ServerURL, FontFamily = Blocks.Mono };
        var redirects = new CheckBox { IsChecked = proxy.RewritesRedirects, Content = "Keep redirects on this address" };
        var footer = new StackPanel { Spacing = 6 };
        var content = new StackPanel { Spacing = 14, Width = 460 };
        content.Children.Add(port);
        content.Children.Add(server);
        var redirectsLine = new StackPanel { Spacing = 2 };
        redirectsLine.Children.Add(redirects);
        redirectsLine.Children.Add(new TextBlock
        {
            Text = "Redirects to the server point back at localhost, so the app keeps going through Reqly.",
            Style = (Style)Application.Current.Resources["SettingsDescriptionStyle"],
            Margin = new Thickness(28, 0, 0, 0),
        });
        content.Children.Add(redirectsLine);
        content.Children.Add(footer);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"],
            Title = isNew ? "New reverse proxy" : "Edit reverse proxy",
            Content = content,
            PrimaryButtonText = isNew ? "Add" : "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = false,
        };
        var edited = proxy;
        var checks = 0;
        async Task CheckAsync()
        {
            var check = ++checks;
            edited = proxy with { Port = port.Text, ServerURL = server.Text, RewritesRedirects = redirects.IsChecked == true };
            WireCheck result;
            try
            {
                result = await connections.CheckReverseProxyAsync(edited);
            }
            catch (CoreProblem failure)
            {
                AppLog.Write($"couldn't check the reverse proxy: {failure.Message}");
                return;
            }
            if (check != checks)
            {
                return;
            }
            footer.Children.Clear();
            if (result.Problem is { } problem)
            {
                footer.Children.Add(Blocks.Failure(problem));
            }
            else if (result.Note is { } note)
            {
                footer.Children.Add(Blocks.Note(note));
            }
            dialog.IsPrimaryButtonEnabled = result.Problem is null;
        }
        port.TextChanged += (_, _) => _ = CheckAsync();
        server.TextChanged += (_, _) => _ = CheckAsync();
        redirects.Click += (_, _) => _ = CheckAsync();
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            if (await connections.SaveReverseProxyAsync(edited) is { } problem)
            {
                args.Cancel = true;
                footer.Children.Clear();
                footer.Children.Add(Blocks.Failure(problem));
            }
            deferral.Complete();
        };
        dialog.Opened += (_, _) => _ = CheckAsync();
        editor = dialog;
        try
        {
            await dialog.ShowAsync();
        }
        catch (Exception error)
        {
            AppLog.Write($"the reverse proxy editor didn't show: {error.Message}");
        }
        finally
        {
            editor = null;
        }
    }
}
