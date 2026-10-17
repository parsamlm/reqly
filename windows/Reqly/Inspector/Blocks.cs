using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Reqly.Inspector;

/// <summary>
/// The details pane's building blocks, as the Mac's: a section with its title and count, a row
/// with a label and a value, and a box around text such as a URL.
/// </summary>
public static class Blocks
{
    public static readonly FontFamily Mono = new("Cascadia Mono, Consolas");

    public static Brush Resource(string name) => (Brush)Application.Current.Resources[name];

    /// <summary>A section: its title, with a count when it has one, then its rows.</summary>
    public static StackPanel Section(string title, int? count = null, FrameworkElement? accessory = null)
    {
        var heading = new Grid { Margin = new Thickness(0, 0, 0, 8), ColumnSpacing = 6 };
        heading.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        heading.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        heading.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var titles = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        titles.Children.Add(new TextBlock { Text = title, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        if (count is int number)
        {
            titles.Children.Add(new TextBlock
            {
                Text = number.ToString("N0"),
                Foreground = Resource("TextFillColorSecondaryBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        heading.Children.Add(titles);
        if (accessory is not null)
        {
            Grid.SetColumn(accessory, 2);
            heading.Children.Add(accessory);
        }
        var section = new StackPanel();
        section.Children.Add(heading);
        return section;
    }

    /// <summary>A row: a label 130 wide, then a value that wraps and can be selected.</summary>
    public static Grid Row(string label, string value, bool monospaced = false, bool allMonospaced = false)
    {
        var row = new Grid
        {
            ColumnSpacing = 12,
            Padding = new Thickness(0, 5, 0, 5),
            BorderThickness = new Thickness(0, 0, 0, 1),
            BorderBrush = Resource("DividerStrokeColorDefaultBrush"),
        };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var name = new TextBlock
        {
            Text = label,
            Foreground = Resource("TextFillColorSecondaryBrush"),
            TextWrapping = TextWrapping.Wrap,
            FontSize = 13,
        };
        if (allMonospaced)
        {
            name.FontFamily = Mono;
            name.FontSize = 12;
        }
        var text = new TextBlock
        {
            Text = value,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            FontSize = 13,
        };
        if (monospaced || allMonospaced)
        {
            text.FontFamily = Mono;
            text.FontSize = 12;
        }
        Grid.SetColumn(text, 1);
        row.Children.Add(name);
        row.Children.Add(text);
        return row;
    }

    /// <summary>Text in a box, such as the URL, or a script's output.</summary>
    public static Border Box(string text, bool monospaced = true)
    {
        return new Border
        {
            Background = Resource("ControlFillColorSecondaryBrush"),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10),
            Child = new TextBlock
            {
                Text = text,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
                FontFamily = monospaced ? Mono : FontFamily.XamlAutoFontFamily,
                FontSize = monospaced ? 12 : 13,
            },
        };
    }

    /// <summary>
    /// A text box's text, with its lines ended as the original's were. A text box ends each line
    /// with a carriage return alone, which isn't how bodies and scripts end them.
    /// </summary>
    public static string LinesAsIn(string text, string original)
    {
        var lines = text.Replace("\r\n", "\n").Replace('\r', '\n');
        return original.Contains("\r\n") ? lines.Replace("\n", "\r\n") : lines;
    }

    /// <summary>Secondary text, such as "No response yet."</summary>
    public static TextBlock Note(string text) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        Foreground = Resource("TextFillColorSecondaryBrush"),
    };

    /// <summary>A failure, in red, with a warning sign. Its text wraps to the room there is.</summary>
    public static Grid Failure(string message)
    {
        var line = new Grid { ColumnSpacing = 8 };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        line.Children.Add(new FontIcon
        {
            Glyph = "\uE7BA",
            FontSize = 13,
            Foreground = Resource("SystemFillColorCriticalBrush"),
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 2, 0, 0),
        });
        var text = new TextBlock
        {
            Text = message,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            Foreground = Resource("SystemFillColorCriticalBrush"),
        };
        Grid.SetColumn(text, 1);
        line.Children.Add(text);
        return line;
    }

    /// <summary>A field's title, in the interface's font even when the field's own text is monospaced.</summary>
    public static TextBlock FieldHeader(string text) => new()
    {
        Text = text,
        FontFamily = (FontFamily)Application.Current.Resources["ContentControlThemeFontFamily"],
    };

    /// <summary>A note under a field, in the interface's font.</summary>
    public static TextBlock FieldDescription(string text) => new()
    {
        Text = text,
        Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        Foreground = Resource("TextFillColorSecondaryBrush"),
        TextWrapping = TextWrapping.Wrap,
    };

    /// <summary>A link-like button, such as Show or Copy Path.</summary>
    public static HyperlinkButton Link(string text, Action action, string? accessibleName = null)
    {
        var link = new HyperlinkButton { Content = text, Padding = new Thickness(2, 0, 2, 0), MinHeight = 0 };
        link.Click += (_, _) => action();
        if (accessibleName is not null)
        {
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(link, accessibleName);
        }
        return link;
    }

    /// <summary>A small icon button with a tooltip, such as Copy Headers.</summary>
    public static Button IconButton(string glyph, string tip, Action action)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 13 },
            Padding = new Thickness(6),
            MinWidth = 0,
            MinHeight = 0,
            Style = (Style)Application.Current.Resources["SubtleButtonStyle"],
        };
        ToolTipService.SetToolTip(button, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, tip);
        button.Click += (_, _) => action();
        return button;
    }

    public static TextBlock Strong(string text) => new()
    {
        Text = text,
        FontWeight = FontWeights.SemiBold,
    };
}
