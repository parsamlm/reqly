using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Reqly.Core;
using Reqly.Inspector;
using Windows.Storage.Pickers;
using Windows.System;

namespace Reqly.Settings;

/// <summary>
/// The Client Certificates page of Settings, as the Mac's: the certificates Reqly presents to
/// servers that ask apps to identify themselves, each for its hosts. The first one in the list
/// for a host is the one presented.
/// </summary>
public sealed partial class ClientCertificateSettingsView : UserControl
{
    private readonly ConnectionsModel connections;
    private readonly Func<IntPtr> window;
    private ContentDialog? editor;

    public ClientCertificateSettingsView(ConnectionsModel connections, Func<IntPtr> window)
    {
        this.connections = connections;
        this.window = window;
        InitializeComponent();
        Loaded += (_, _) =>
        {
            connections.Changed += Show;
            Show();
        };
        Unloaded += (_, _) => connections.Changed -= Show;
    }

    private WireClientCertificate? Selected => (CertificateList.SelectedItem as ListViewItem)?.Tag as WireClientCertificate;

    /// <summary>What the page shows, for the self-check.</summary>
    public string Describe() => string.Join(", ", connections.Connections.ClientCertificates.Select(certificate => $"{certificate.Name} for {certificate.Hosts}"));

    private void Show()
    {
        var selected = Selected?.Id;
        CertificateList.Items.Clear();
        foreach (var certificate in connections.Connections.ClientCertificates)
        {
            var item = new ListViewItem { Content = Row(certificate), Tag = certificate };
            CertificateList.Items.Add(item);
            if (certificate.Id == selected)
            {
                CertificateList.SelectedItem = item;
            }
        }
        var isEmpty = connections.Connections.ClientCertificates.Length == 0;
        NoCertificates.Visibility = isEmpty ? Visibility.Visible : Visibility.Collapsed;
        CertificateList.Visibility = isEmpty ? Visibility.Collapsed : Visibility.Visible;
        Problems.Children.Clear();
        if (connections.Connections.Problem is { } problem)
        {
            Problems.Children.Add(Blocks.Failure(problem));
        }
        RemoveButton.IsEnabled = EditButton.IsEnabled = Selected is not null;
    }

    /// <summary>A certificate: its switch, its name and hosts, and who issued it and when it expires.</summary>
    private Grid Row(WireClientCertificate certificate)
    {
        var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 6, 0, 6), Opacity = certificate.IsOn ? 1 : 0.6 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var toggle = new ToggleSwitch { IsOn = certificate.IsOn, OnContent = "", OffContent = "", MinWidth = 0, Width = 44, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(toggle, "Use this certificate");
        toggle.Toggled += (_, _) =>
        {
            if (toggle.IsOn != certificate.IsOn)
            {
                _ = connections.SetClientCertificateOnAsync(certificate.Id, toggle.IsOn);
            }
        };
        var icon = new FontIcon { Glyph = "", FontSize = 18, VerticalAlignment = VerticalAlignment.Center, Foreground = Blocks.Resource("TextFillColorSecondaryBrush") };
        var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock { Text = certificate.Name, TextTrimming = TextTrimming.CharacterEllipsis });
        words.Children.Add(new TextBlock { Text = certificate.Hosts, FontFamily = Blocks.Mono, FontSize = 12, Foreground = Blocks.Resource("TextFillColorSecondaryBrush"), TextTrimming = TextTrimming.CharacterEllipsis });
        words.Children.Add(Details(certificate));
        Grid.SetColumn(icon, 1);
        Grid.SetColumn(words, 2);
        row.Children.Add(toggle);
        row.Children.Add(icon);
        row.Children.Add(words);
        return row;
    }

    private static UIElement Details(WireClientCertificate certificate)
    {
        if (certificate.IsMissing)
        {
            return Blocks.Failure("Reqly no longer has this certificate's key. Remove it and add it again.");
        }
        var line = new TextBlock { Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], TextWrapping = TextWrapping.Wrap };
        if (certificate.Issuer.Length > 0)
        {
            line.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = $"Issued by {certificate.Issuer}", Foreground = Blocks.Resource("TextFillColorSecondaryBrush") });
        }
        if (certificate.Expires is double expires)
        {
            var date = DateTime.UnixEpoch.AddSeconds(expires).ToLocalTime().ToString("d", CultureInfo.CurrentCulture);
            if (line.Inlines.Count > 0)
            {
                line.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = " · ", Foreground = Blocks.Resource("TextFillColorSecondaryBrush") });
            }
            line.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run
            {
                Text = certificate.HasExpired ? $"Expired on {date}" : $"Expires on {date}",
                Foreground = Blocks.Resource(certificate.HasExpired ? "SystemFillColorCriticalBrush" : "TextFillColorSecondaryBrush"),
            });
        }
        return line;
    }

    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e) => RemoveButton.IsEnabled = EditButton.IsEnabled = Selected is not null;

    private void OnRemoveClicked(object sender, RoutedEventArgs e) => Remove(Selected);

    private void Remove(WireClientCertificate? certificate)
    {
        if (certificate is not null)
        {
            _ = connections.RemoveClientCertificateAsync(certificate.Id);
        }
    }

    private async void OnEditClicked(object sender, RoutedEventArgs e) => await EditHostsAsync(Selected);

    private async void OnListDoubleTapped(object sender, DoubleTappedRoutedEventArgs e) => await EditHostsAsync(Selected);

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
        ListViewItem? item = null;
        for (var element = args.OriginalSource as DependencyObject; element is not null && item is null; element = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(element))
        {
            item = element as ListViewItem;
        }
        if (item?.Tag is not WireClientCertificate certificate)
        {
            return;
        }
        args.Handled = true;
        CertificateList.SelectedItem = item;
        var menu = new MenuFlyout();
        var edit = new MenuFlyoutItem { Text = "Edit hosts…" };
        edit.Click += async (_, _) => await EditHostsAsync(certificate);
        var remove = new MenuFlyoutItem { Text = "Remove" };
        remove.Click += (_, _) => Remove(certificate);
        menu.Items.Add(edit);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(remove);
        if (args.TryGetPosition(CertificateList, out var point))
        {
            menu.ShowAt(CertificateList, point);
        }
        else
        {
            menu.ShowAt(item);
        }
    }

    // MARK: Adding

    private async void OnAddClicked(object sender, RoutedEventArgs e) => await AddAsync();

    /// <summary>Reads a certificate and its private key from a .p12 or .pfx file, or from PEM files, for the hosts you type.</summary>
    public async Task AddAsync(IReadOnlyList<string>? chosenFiles = null, string? typedHosts = null)
    {
        if (editor is not null || XamlRoot is null)
        {
            return;
        }
        var files = chosenFiles?.ToList() ?? [];
        var hosts = new TextBox { Header = Blocks.FieldHeader("Hosts"), PlaceholderText = "api.example.com, *.example.com", FontFamily = Blocks.Mono, Text = typedHosts ?? "" };
        var chosen = new TextBlock { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        var choose = new Button { Content = "Choose…" };
        var password = new PasswordBox { Header = "Password", PlaceholderText = "If the file is locked" };
        var footer = new StackPanel { Spacing = 6 };
        var hint = Blocks.Note("Choose a .p12 or .pfx file, or PEM files with the certificate and its private key.");
        var certificateLine = new StackPanel { Spacing = 4 };
        certificateLine.Children.Add(new TextBlock { Text = "Certificate" });
        var fileRow = new Grid { ColumnSpacing = 12 };
        fileRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        fileRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        fileRow.Children.Add(chosen);
        Grid.SetColumn(choose, 1);
        fileRow.Children.Add(choose);
        certificateLine.Children.Add(fileRow);
        var content = new StackPanel { Spacing = 14, Width = 480 };
        content.Children.Add(hosts);
        content.Children.Add(certificateLine);
        content.Children.Add(password);
        content.Children.Add(footer);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"],
            Title = "Add client certificate",
            Content = content,
            PrimaryButtonText = "Add",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = false,
        };
        var hostCount = 0;
        void ShowFiles()
        {
            chosen.Text = files.Count == 0 ? "None" : string.Join(", ", files.Select(Path.GetFileName));
            chosen.Foreground = Blocks.Resource(files.Count == 0 ? "TextFillColorSecondaryBrush" : "TextFillColorPrimaryBrush");
            dialog.IsPrimaryButtonEnabled = files.Count > 0 && hostCount > 0;
        }
        void ShowProblem(string? problem)
        {
            footer.Children.Clear();
            footer.Children.Add(problem is null ? hint : Blocks.Failure(problem));
        }
        async Task CheckHostsAsync()
        {
            try
            {
                hostCount = (await connections.CheckHostsAsync(hosts.Text)).Count;
            }
            catch (CoreProblem failure)
            {
                AppLog.Write($"couldn't check the hosts: {failure.Message}");
            }
            ShowFiles();
        }
        hosts.TextChanged += (_, _) =>
        {
            ShowProblem(null);
            _ = CheckHostsAsync();
        };
        password.PasswordChanged += (_, _) => ShowProblem(null);
        choose.Click += async (_, _) =>
        {
            var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
            foreach (var type in new[] { ".p12", ".pfx", ".pem", ".crt", ".cer", ".key" })
            {
                picker.FileTypeFilter.Add(type);
            }
            WinRT.Interop.InitializeWithWindow.Initialize(picker, window());
            if (await picker.PickMultipleFilesAsync() is { Count: > 0 } picked)
            {
                files = [.. picked.Select(file => file.Path)];
                ShowProblem(null);
                ShowFiles();
            }
        };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            if (await connections.AddClientCertificateAsync(files, password.Password, hosts.Text) is { } problem)
            {
                args.Cancel = true;
                ShowProblem(problem);
            }
            deferral.Complete();
        };
        ShowProblem(null);
        ShowFiles();
        dialog.Opened += (_, _) => _ = CheckHostsAsync();
        editor = dialog;
        try
        {
            await dialog.ShowAsync();
        }
        catch (Exception error)
        {
            AppLog.Write($"the certificate dialog didn't show: {error.Message}");
        }
        finally
        {
            editor = null;
        }
    }

    // MARK: Changing its hosts

    private async Task EditHostsAsync(WireClientCertificate? certificate)
    {
        if (certificate is null || editor is not null || XamlRoot is null)
        {
            return;
        }
        var hosts = new TextBox { Header = Blocks.FieldHeader("Hosts"), PlaceholderText = "api.example.com, *.example.com", FontFamily = Blocks.Mono, Text = certificate.Hosts };
        var footer = new StackPanel();
        var content = new StackPanel { Spacing = 14, Width = 420 };
        content.Children.Add(hosts);
        content.Children.Add(footer);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"],
            Title = certificate.Name,
            Content = content,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        async Task CheckAsync()
        {
            try
            {
                var check = await connections.CheckHostsAsync(hosts.Text);
                footer.Children.Clear();
                if (check.Problem is { } problem)
                {
                    footer.Children.Add(Blocks.Failure(problem));
                }
                dialog.IsPrimaryButtonEnabled = check.Problem is null && check.Count > 0;
            }
            catch (CoreProblem failure)
            {
                AppLog.Write($"couldn't check the hosts: {failure.Message}");
            }
        }
        hosts.TextChanged += (_, _) => _ = CheckAsync();
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            if (await connections.SetClientCertificateHostsAsync(certificate.Id, hosts.Text) is { } problem)
            {
                args.Cancel = true;
                footer.Children.Clear();
                footer.Children.Add(Blocks.Failure(problem));
            }
            deferral.Complete();
        };
        editor = dialog;
        try
        {
            await dialog.ShowAsync();
        }
        catch (Exception error)
        {
            AppLog.Write($"the hosts dialog didn't show: {error.Message}");
        }
        finally
        {
            editor = null;
        }
    }
}
