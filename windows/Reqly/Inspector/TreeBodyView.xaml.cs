using System.Collections.ObjectModel;
using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Reqly.Core;
using Reqly.Traffic;

namespace Reqly.Inspector;

/// <summary>
/// A body's tree: at first the root and its children that hold others are open, and deeper rows
/// are made as they open. The filter shows the rows whose key or value has the text, with their
/// parents, all open.
/// </summary>
public sealed partial class TreeBodyView : UserControl
{
    private readonly WireTreeNode[] nodes;
    /// <summary>Asks the core for a row's path and its value to copy.</summary>
    private readonly Func<int, Task<(string Path, string Copy)?>> describe;
    private readonly Action<string> copy;
    private readonly ObservableCollection<TreeItem> roots = [];
    private (string Path, string Copy)? selected;

    public TreeBodyView(WireTree tree, double maxHeight, Func<int, Task<(string Path, string Copy)?>> describe, Action<string> copy)
    {
        nodes = tree.Nodes;
        this.describe = describe;
        this.copy = copy;
        InitializeComponent();
        Tree.MaxHeight = maxHeight;
        Tree.ItemsSource = roots;
        ShowAll();
    }

    private void ShowAll()
    {
        roots.Clear();
        if (nodes.Length == 0)
        {
            return;
        }
        var root = Item(0);
        Realize(root);
        root.IsExpanded = true;
        foreach (var child in root.Children)
        {
            if (nodes[child.Id].Children.Length > 0)
            {
                Realize(child);
                child.IsExpanded = true;
            }
        }
        roots.Add(root);
    }

    private TreeItem Item(int id)
    {
        var node = nodes[id];
        return new TreeItem(id, node, node.Children.Length > 0);
    }

    /// <summary>Makes a row's children, once.</summary>
    private void Realize(TreeItem item)
    {
        if (!item.HasUnrealizedChildren)
        {
            return;
        }
        foreach (var child in nodes[item.Id].Children)
        {
            item.Children.Add(Item(child));
        }
        item.HasUnrealizedChildren = false;
    }

    private void OnExpanding(TreeView sender, TreeViewExpandingEventArgs args)
    {
        if (args.Item is TreeItem item)
        {
            Realize(item);
        }
    }

    private async void OnItemInvoked(TreeView sender, TreeViewItemInvokedEventArgs args)
    {
        if (args.InvokedItem is not TreeItem item)
        {
            return;
        }
        selected = await describe(item.Id);
        PathBar.Visibility = selected is null ? Visibility.Collapsed : Visibility.Visible;
        // The root has no path of its own.
        PathText.Text = selected is { Path: { Length: > 0 } path } ? path : item.Label;
    }

    private void OnCopyPathClicked(object sender, RoutedEventArgs e)
    {
        if (selected is { } row)
        {
            copy(row.Path);
        }
    }

    private void OnCopyValueClicked(object sender, RoutedEventArgs e)
    {
        if (selected is { } row)
        {
            copy(row.Copy);
        }
    }

    private void OnFilterChanged(object sender, TextChangedEventArgs e)
    {
        var text = Filter.Text.Trim();
        if (text.Length == 0)
        {
            ShowAll();
            return;
        }
        // The rows that match, then their parents.
        var shown = new HashSet<int>();
        for (var id = 0; id < nodes.Length; id++)
        {
            var node = nodes[id];
            var matches = node.Label.Contains(text, StringComparison.CurrentCultureIgnoreCase)
                || (node.Children.Length == 0 && node.Summary.Contains(text, StringComparison.CurrentCultureIgnoreCase));
            if (!matches)
            {
                continue;
            }
            // A row that matches shows with its parents, up to one shown already.
            int? at = id;
            while (at is int place && shown.Add(place))
            {
                at = nodes[place].Parent;
            }
        }
        roots.Clear();
        if (shown.Contains(0))
        {
            roots.Add(Filtered(0, shown));
        }
    }

    private TreeItem Filtered(int id, HashSet<int> shown)
    {
        var item = new TreeItem(id, nodes[id], false) { IsExpanded = true };
        foreach (var child in nodes[id].Children.Where(shown.Contains))
        {
            item.Children.Add(Filtered(child, shown));
        }
        return item;
    }
}

/// <summary>A row of the tree, made when its parent opens.</summary>
public sealed partial class TreeItem(int id, WireTreeNode node, bool hasChildren) : INotifyPropertyChanged
{
    private bool isExpanded;
    private bool hasUnrealizedChildren = hasChildren;

    public int Id { get; } = id;
    public string Label { get; } = node.Label;
    public string Summary { get; } = node.Summary;
    public string Type { get; } = node.Type;
    public ObservableCollection<TreeItem> Children { get; } = [];

    /// <summary>Strings and bytes, numbers and literals in their code colors; a container's summary in secondary text.</summary>
    public Brush ValueBrush => node.Style switch
    {
        "string" or "bytes" => Palette.Code("string"),
        "number" => Palette.Code("number"),
        "literal" => Palette.Code("literal"),
        _ => Blocks.Resource("TextFillColorSecondaryBrush"),
    };

    public bool HasUnrealizedChildren
    {
        get => hasUnrealizedChildren;
        set
        {
            hasUnrealizedChildren = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(HasUnrealizedChildren)));
        }
    }

    public bool IsExpanded
    {
        get => isExpanded;
        set
        {
            if (isExpanded != value)
            {
                isExpanded = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsExpanded)));
            }
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public override string ToString() => $"{Label}: {Summary}";
}
