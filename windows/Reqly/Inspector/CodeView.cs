using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Reqly.Core;
using Reqly.Traffic;

namespace Reqly.Inspector;

/// <summary>
/// Code or text as the Mac's code view shows it: colored by its tokens, code with line numbers
/// in whole lines that scroll sideways, text wrapping. It scrolls inside itself once it's taller
/// than its height limit.
/// </summary>
public sealed partial class CodeView : UserControl
{
    /// <summary>Text past this isn't shown, so the pane stays quick. The Raw tab and Hex show more.</summary>
    public const int ShowLimit = 1_000_000;
    /// <summary>Text past this shows without colors, as a long one takes a while to color.</summary>
    private const int ColorLimit = 300_000;
    private const double LineHeight = 17;

    public CodeView(WireCode code, double maxHeight)
    {
        var frame = new Border { Background = Palette.CodeBackground, CornerRadius = new CornerRadius(10) };
        Content = frame;
        var text = code.Text.Length > ShowLimit ? code.Text[..ShowLimit] : code.Text;
        var body = new RichTextBlock
        {
            FontFamily = Blocks.Mono,
            FontSize = 12,
            LineHeight = LineHeight,
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
            IsTextSelectionEnabled = true,
            TextWrapping = code.IsCode ? TextWrapping.NoWrap : TextWrapping.Wrap,
            Padding = new Thickness(4, 10, 10, 10),
        };
        body.Blocks.Add(Paragraph(text, text.Length <= ColorLimit ? code.Tokens : [], code.IsCode));
        if (code.Text.Length > ShowLimit)
        {
            var more = new Paragraph { Margin = new Thickness(0, 8, 0, 0) };
            more.Inlines.Add(new Run
            {
                Text = $"‹Shows the first {ShowLimit:N0} characters of {code.Text.Length:N0}.›",
                Foreground = Palette.Code("comment"),
            });
            body.Blocks.Add(more);
        }
        var content = new Grid();
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        if (code.IsCode)
        {
            // Code keeps whole lines, so each line number sits beside its line.
            var lines = text.Count(character => character == '\n') + (text.EndsWith('\n') ? 0 : 1);
            var numbers = new StringBuilder();
            for (var line = 1; line <= lines; line++)
            {
                numbers.Append(line).Append('\n');
            }
            content.Children.Add(new TextBlock
            {
                Text = numbers.ToString().TrimEnd('\n'),
                FontFamily = Blocks.Mono,
                FontSize = 11,
                LineHeight = LineHeight,
                LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
                TextAlignment = TextAlignment.Right,
                Foreground = Palette.Code("comment"),
                MinWidth = 32,
                Padding = new Thickness(8, 10, 8, 10),
                IsHitTestVisible = false,
            });
        }
        Grid.SetColumn(body, 1);
        content.Children.Add(body);
        frame.Child = new ScrollViewer
        {
            Content = content,
            MaxHeight = maxHeight,
            HorizontalScrollBarVisibility = code.IsCode ? ScrollBarVisibility.Auto : ScrollBarVisibility.Disabled,
            HorizontalScrollMode = code.IsCode ? ScrollMode.Auto : ScrollMode.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
    }

    /// <summary>The text as runs: each token in its color, the rest in the code's or the text's own.</summary>
    private static Paragraph Paragraph(string text, JsonElement[][] tokens, bool isCode)
    {
        var paragraph = new Paragraph();
        var plain = isCode ? Palette.Code(null) : Palette.Text;
        var at = 0;
        foreach (var token in tokens.OrderBy(token => token[0].GetInt32()))
        {
            var location = token[0].GetInt32();
            var length = token[1].GetInt32();
            if (location < at || location + length > text.Length)
            {
                continue;
            }
            if (location > at)
            {
                paragraph.Inlines.Add(new Run { Text = text[at..location], Foreground = plain });
            }
            paragraph.Inlines.Add(new Run { Text = text.Substring(location, length), Foreground = Palette.Code(token[2].GetString()) });
            at = location + length;
        }
        if (at < text.Length)
        {
            paragraph.Inlines.Add(new Run { Text = text[at..], Foreground = plain });
        }
        return paragraph;
    }
}
