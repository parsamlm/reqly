using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Reqly.Core;
using Reqly.Inspector;

namespace Reqly.Rules;

/// <summary>The fields every rule has: its name, and the host, path and method it matches.</summary>
internal sealed class MatchFields
{
    public static readonly string[] Methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"];

    public TextBox Name { get; } = new() { Header = "Name" };
    public TextBox Host { get; } = new() { Header = Blocks.FieldHeader("Host"), PlaceholderText = "Any host", FontFamily = Blocks.Mono };
    public TextBox Path { get; } = new()
    {
        Header = Blocks.FieldHeader("Path"),
        PlaceholderText = "Any path",
        FontFamily = Blocks.Mono,
        Description = Blocks.FieldDescription("Use * to match anything."),
    };
    public ComboBox Method { get; } = new() { Header = "Method", MinWidth = 140 };

    public MatchFields(WireRuleDraft draft, Action changed)
    {
        Name.Text = draft.Name;
        Host.Text = draft.Host;
        Path.Text = draft.Path;
        Method.Items.Add("Any");
        // A method of the request's own, such as PROPFIND, stays one to choose.
        if (draft.Method.Length > 0 && !Methods.Contains(draft.Method))
        {
            Method.Items.Add(draft.Method);
        }
        foreach (var method in Methods)
        {
            Method.Items.Add(method);
        }
        Method.SelectedItem = draft.Method.Length > 0 ? draft.Method : "Any";
        Name.TextChanged += (_, _) =>
        {
            draft.Name = Name.Text;
            changed();
        };
        Host.TextChanged += (_, _) =>
        {
            draft.Host = Host.Text;
            changed();
        };
        Path.TextChanged += (_, _) =>
        {
            draft.Path = Path.Text;
            changed();
        };
        Method.SelectionChanged += (_, _) =>
        {
            draft.Method = Method.SelectedItem is string method && method != "Any" ? method : "";
            changed();
        };
    }

    /// <summary>The name a rule gets when you don't give it one, shown in its field.</summary>
    public void ShowDefaultName(string name) => Name.PlaceholderText = name;
}

/// <summary>How many requests captured so far a rule matches, as you edit it.</summary>
internal sealed class MatchLine
{
    private readonly Ellipse dot = new() { Width = 7, Height = 7, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock text = new() { FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };

    public StackPanel View { get; } = new() { Orientation = Orientation.Horizontal, Spacing = 8 };

    public MatchLine()
    {
        View.Children.Add(dot);
        View.Children.Add(text);
        Show(0);
    }

    public string Text => text.Text;

    public void Show(int count)
    {
        text.Text = count switch
        {
            0 => "Matches no requests captured so far",
            1 => "Matches 1 request captured so far",
            _ => $"Matches {count:N0} requests captured so far",
        };
        dot.Fill = Blocks.Resource(count > 0 ? "AccentFillColorDefaultBrush" : "ControlStrongFillColorDisabledBrush");
        text.Foreground = Blocks.Resource(count > 0 ? "AccentTextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush");
    }
}

/// <summary>What to fix before a rule can be saved, under its fields.</summary>
internal sealed class ProblemLine
{
    private readonly TextBlock text = new() { TextWrapping = TextWrapping.Wrap, Foreground = Blocks.Resource("SystemFillColorCautionBrush") };

    public StackPanel View { get; } = new() { Orientation = Orientation.Horizontal, Spacing = 8, Visibility = Visibility.Collapsed };

    public ProblemLine()
    {
        View.Children.Add(new FontIcon { Glyph = "", FontSize = 13, Foreground = Blocks.Resource("SystemFillColorCautionBrush"), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) });
        View.Children.Add(text);
        AutomationProperties.SetLiveSetting(text, AutomationLiveSetting.Polite);
    }

    public string? Problem { get; private set; }

    public void Show(string? problem)
    {
        Problem = problem;
        text.Text = problem ?? "";
        View.Visibility = problem is null ? Visibility.Collapsed : Visibility.Visible;
    }
}

internal static class Dialogs
{
    /// <summary>A dialog as wide as its editor needs, rather than ContentDialog's narrow default.</summary>
    public static void Widen(ContentDialog dialog, double width)
    {
        dialog.Resources["ContentDialogMaxWidth"] = width;
        dialog.Resources["ContentDialogMaxHeight"] = 2000.0;
    }

    public static Grid Columns(params (FrameworkElement Element, GridLength Width)[] cells)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        for (var index = 0; index < cells.Length; index++)
        {
            // A field with a note under it is taller than the others; they all start at the top.
            cells[index].Element.VerticalAlignment = cells[index].Element is Button ? VerticalAlignment.Bottom : VerticalAlignment.Top;
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = cells[index].Width });
            Grid.SetColumn(cells[index].Element, index);
            grid.Children.Add(cells[index].Element);
        }
        return grid;
    }

    public static readonly GridLength Star = new(1, GridUnitType.Star);
}
