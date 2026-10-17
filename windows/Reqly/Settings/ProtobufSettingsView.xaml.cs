using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Reqly.Core;
using Reqly.Inspector;
using Windows.Storage.Pickers;
using Windows.System;

namespace Reqly.Settings;

/// <summary>
/// The Protobuf page of Settings, as the Mac's: the .proto files and folders Reqly reads protobuf
/// and gRPC bodies with, how many files each holds, and what Reqly couldn't use in them.
/// </summary>
public sealed partial class ProtobufSettingsView : UserControl
{
    private readonly ProtobufModel protobuf;
    private readonly Func<IntPtr> window;

    public ProtobufSettingsView(ProtobufModel protobuf, Func<IntPtr> window)
    {
        this.protobuf = protobuf;
        this.window = window;
        InitializeComponent();
        Loaded += (_, _) =>
        {
            protobuf.Changed += Show;
            Show();
        };
        Unloaded += (_, _) => protobuf.Changed -= Show;
    }

    private WireProtobufSource? Selected => (SourceList.SelectedItem as ListViewItem)?.Tag as WireProtobufSource;

    /// <summary>What the page shows, for the self-check.</summary>
    public string Describe() => $"{string.Join(", ", protobuf.Protobuf.Sources.Select(source => $"{source.Name} ({CountText(source)})"))} · {protobuf.Protobuf.Summary} · {protobuf.Protobuf.Problems.Length} problems";

    private void Show()
    {
        var shown = protobuf.Protobuf;
        var selected = Selected?.Path;
        SourceList.Items.Clear();
        foreach (var source in shown.Sources)
        {
            var item = new ListViewItem { Content = Row(source), Tag = source };
            SourceList.Items.Add(item);
            if (source.Path == selected)
            {
                SourceList.SelectedItem = item;
            }
        }
        NoSources.Visibility = shown.Sources.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        SourceList.Visibility = shown.Sources.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        Summary.Text = shown.Summary;
        Summary.Visibility = shown.Summary.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        LoadingRing.IsActive = protobuf.IsLoading;
        ReloadButton.IsEnabled = shown.Sources.Length > 0 && !protobuf.IsLoading;
        RemoveButton.IsEnabled = Selected is not null;
        ProblemRows.Children.Clear();
        if (shown.SaveProblem is { } saving)
        {
            ProblemRows.Children.Add(Blocks.Failure(saving));
        }
        foreach (var problem in shown.Problems)
        {
            var row = new StackPanel { Spacing = 2 };
            row.Children.Add(new TextBlock { Text = problem.Line > 0 ? $"{problem.File}, line {problem.Line}" : problem.File, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, IsTextSelectionEnabled = true });
            row.Children.Add(new TextBlock { Text = problem.Message, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, Foreground = Blocks.Resource("TextFillColorSecondaryBrush") });
            ProblemRows.Children.Add(row);
        }
        ProblemSection.Visibility = ProblemRows.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private static string CountText(WireProtobufSource source) => source.Count switch
    {
        null => "Missing",
        1 => "1 file",
        int count => $"{count:N0} files",
    };

    /// <summary>A file or a folder: its name and where it is, and how many .proto files it holds.</summary>
    private static Grid Row(WireProtobufSource source)
    {
        var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 6, 0, 6) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(new FontIcon { Glyph = source.IsFolder ? "\uE8B7" : "\uE8A5", FontSize = 16, VerticalAlignment = VerticalAlignment.Center, Foreground = Blocks.Resource("TextFillColorSecondaryBrush") });
        var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock { Text = source.Name, TextTrimming = TextTrimming.CharacterEllipsis });
        words.Children.Add(new TextBlock { Text = Shown(source.Path), Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Foreground = Blocks.Resource("TextFillColorSecondaryBrush"), TextTrimming = TextTrimming.CharacterEllipsis });
        Grid.SetColumn(words, 1);
        row.Children.Add(words);
        var count = new TextBlock { Text = CountText(source), VerticalAlignment = VerticalAlignment.Center, Foreground = Blocks.Resource("TextFillColorSecondaryBrush") };
        Grid.SetColumn(count, 2);
        row.Children.Add(count);
        return row;
    }

    /// <summary>A path as Windows writes it, with backslashes, from the core's /C:/… form.</summary>
    private static string Shown(string path)
    {
        var trimmed = path.Length > 2 && path[0] == '/' && path[2] == ':' ? path[1..] : path;
        return trimmed.TrimEnd('/').Replace('/', '\\');
    }

    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e) => RemoveButton.IsEnabled = Selected is not null;

    private void OnRemoveClicked(object sender, RoutedEventArgs e) => Remove(Selected);

    private void Remove(WireProtobufSource? source)
    {
        if (source is not null)
        {
            _ = protobuf.RemoveAsync(source.Path);
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

    private void OnReloadClicked(object sender, RoutedEventArgs e) => _ = protobuf.ReloadAsync();

    private async void OnAddFilesClicked(object sender, RoutedEventArgs e) => await AddFilesAsync(protobuf, window);

    private async void OnAddFolderClicked(object sender, RoutedEventArgs e) => await AddFolderAsync(protobuf, window);

    /// <summary>Adds .proto files you choose. The body viewer offers it too.</summary>
    public static async Task AddFilesAsync(ProtobufModel protobuf, Func<IntPtr> window)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".proto");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, window());
        if (await picker.PickMultipleFilesAsync() is { Count: > 0 } files)
        {
            await protobuf.AddAsync(files.Select(file => file.Path));
        }
    }

    /// <summary>Adds a folder of .proto files, which includes the files others import.</summary>
    public static async Task AddFolderAsync(ProtobufModel protobuf, Func<IntPtr> window)
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, window());
        if (await picker.PickSingleFolderAsync() is { } folder)
        {
            await protobuf.AddAsync([folder.Path]);
        }
    }

    private void OnContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        ListViewItem? item = null;
        for (var element = args.OriginalSource as DependencyObject; element is not null && item is null; element = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(element))
        {
            item = element as ListViewItem;
        }
        if (item?.Tag is not WireProtobufSource source)
        {
            return;
        }
        args.Handled = true;
        SourceList.SelectedItem = item;
        var menu = new MenuFlyout();
        var reveal = new MenuFlyoutItem { Text = "Show in File Explorer" };
        // Through the shell, so File Explorer inherits none of Reqly's handles, its sockets among them.
        reveal.Click += (_, _) => Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{Shown(source.Path)}\"") { UseShellExecute = true });
        var remove = new MenuFlyoutItem { Text = "Remove" };
        remove.Click += (_, _) => Remove(source);
        menu.Items.Add(reveal);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(remove);
        if (args.TryGetPosition(SourceList, out var point))
        {
            menu.ShowAt(SourceList, point);
        }
        else
        {
            menu.ShowAt(item);
        }
    }
}
