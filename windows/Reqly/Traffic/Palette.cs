using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Reqly.Traffic;

/// <summary>
/// The colors that carry meaning in the list, for light and dark mode, as the design guidelines
/// set them: status dots (2xx is Reqly teal, the rest are Windows' own hues) and the colors a
/// request can be marked with. Text stays in the theme's own colors.
/// </summary>
public static class Palette
{
    private static bool isDark;
    private static readonly Dictionary<(string, bool), SolidColorBrush> Brushes = [];

    /// <summary>Light or dark changed: rows read their brushes again.</summary>
    public static event Action? Changed;

    public static void Use(ElementTheme theme)
    {
        var dark = theme == ElementTheme.Dark;
        if (dark != isDark)
        {
            isDark = dark;
            Changed?.Invoke();
        }
    }

    /// <summary>A status class's dot: informational, success, redirection, clientError or serverError.</summary>
    public static Brush Status(string? statusClass) => statusClass switch
    {
        "success" => Brush("success", Rgb(0x0B, 0x9A, 0x83), Rgb(0x3F, 0xDD, 0xC0)),
        "redirection" => Brush("redirection", Rgb(0x00, 0x5F, 0xB8), Rgb(0x60, 0xCD, 0xFF)),
        "clientError" => Brush("clientError", Rgb(0xC7, 0x50, 0x0E), Rgb(0xFF, 0x9A, 0x4D)),
        "serverError" => Brush("serverError", Rgb(0xC4, 0x2B, 0x1C), Rgb(0xFF, 0x99, 0xA4)),
        _ => Brush("gray", Rgb(0x8A, 0x8A, 0x8A), Rgb(0x9E, 0x9E, 0x9E)),
    };

    /// <summary>The red of a failure's warning sign.</summary>
    public static Brush Failure => Status("serverError");

    /// <summary>A mark: red, orange, yellow, green, blue, purple or gray.</summary>
    public static Brush Mark(string color) => color switch
    {
        "red" => Brush("mark-red", Rgb(0xE8, 0x3B, 0x30), Rgb(0xFF, 0x45, 0x3A)),
        "orange" => Brush("mark-orange", Rgb(0xF0, 0x8A, 0x00), Rgb(0xFF, 0x9F, 0x0A)),
        "yellow" => Brush("mark-yellow", Rgb(0xE5, 0xB8, 0x00), Rgb(0xFF, 0xD6, 0x0A)),
        "green" => Brush("mark-green", Rgb(0x2E, 0xB3, 0x4F), Rgb(0x30, 0xD1, 0x58)),
        "blue" => Brush("mark-blue", Rgb(0x00, 0x6E, 0xE6), Rgb(0x0A, 0x84, 0xFF)),
        "purple" => Brush("mark-purple", Rgb(0xA0, 0x46, 0xD6), Rgb(0xBF, 0x5A, 0xF2)),
        _ => Brush("mark-gray", Rgb(0x8E, 0x8E, 0x93), Rgb(0x98, 0x98, 0x9D)),
    };

    /// <summary>A marked row's tint: its mark's color, faintly, so the text stays easy to read.</summary>
    public static Brush Tint(string color)
    {
        var key = ("tint-" + color, isDark);
        if (!Brushes.TryGetValue(key, out var brush))
        {
            var mark = ((SolidColorBrush)Mark(color)).Color;
            mark.A = (byte)(isDark ? 36 : 26);
            brush = new SolidColorBrush(mark);
            Brushes[key] = brush;
        }
        return brush;
    }

    public static readonly string[] MarkColors = ["red", "orange", "yellow", "green", "blue", "purple", "gray"];

    /// <summary>Behind code and bytes, as the Mac's code views have it.</summary>
    public static Brush CodeBackground => Brush("code-background", Rgb(0xF6, 0xF7, 0xF7), Rgb(0x24, 0x25, 0x28));

    /// <summary>A token's color: key, string, number, literal, keyword, tag, attribute, attributeValue or comment.</summary>
    public static Brush Code(string? kind) => kind switch
    {
        "key" => Brush("code-key", Rgb(0x1D, 0x1D, 0x1F), Rgb(0xF5, 0xF5, 0xF7)),
        "string" or "attributeValue" => Brush("code-string", Rgb(0xAE, 0x4F, 0x18), Rgb(0xFF, 0xA3, 0x6E)),
        "number" or "tag" => Brush("code-number", Rgb(0x1F, 0x5F, 0xD1), Rgb(0x72, 0xAA, 0xFF)),
        "literal" or "attribute" or "keyword" => Brush("code-literal", Rgb(0x8E, 0x3B, 0xB5), Rgb(0xD5, 0x9C, 0xFF)),
        "comment" => Brush("code-comment", Rgb(0x8E, 0x8E, 0x93), Rgb(0x8D, 0x8D, 0x93)),
        _ => Brush("code-punctuation", Rgb(0x6C, 0x6C, 0x71), Rgb(0x9A, 0x9A, 0xA1)),
    };

    /// <summary>Plain text in a code view, which isn't code.</summary>
    public static Brush Text => Brush("text", Rgb(0x1A, 0x1A, 0x1A), Rgb(0xFF, 0xFF, 0xFF));

    public static string MarkName(string color) => char.ToUpperInvariant(color[0]) + color[1..];

    private static SolidColorBrush Brush(string name, Color light, Color dark)
    {
        var key = (name, isDark);
        if (!Brushes.TryGetValue(key, out var brush))
        {
            brush = new SolidColorBrush(isDark ? dark : light);
            Brushes[key] = brush;
        }
        return brush;
    }

    private static Color Rgb(byte red, byte green, byte blue) => ColorHelper.FromArgb(255, red, green, blue);
}
