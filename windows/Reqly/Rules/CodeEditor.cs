using System.Text;
using System.Text.Json;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Reqly.Core;
using Reqly.Inspector;
using Reqly.Traffic;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.System;
using Windows.UI.Core;

namespace Reqly.Rules;

/// <summary>
/// Edits code in a monospaced font, with its syntax colored as you type and line numbers beside
/// it, as the Mac's script editor does. The core reads the code, the same way on both systems.
/// </summary>
/// <remarks>
/// WinUI's RichEditBox holds the colors. It would undo each coloring along with the typing, so the
/// editor keeps the history of the text itself. It also keeps the text with line feeds, where the
/// box ends its lines with carriage returns.
/// </remarks>
public sealed partial class CodeEditor : UserControl
{
    /// <summary>A line's height, beside the code and in it.</summary>
    private const double LineHeight = 18;
    /// <summary>The room between the box's edge and the code.</summary>
    private const double Inset = 8;
    /// <summary>How many steps undoing goes back.</summary>
    private const int HistoryLimit = 500;

    private enum Edit
    {
        Typing,
        Deleting,
        Other,
    }

    private readonly Func<string, Task<JsonElement[][]>> highlight;
    private readonly RichEditBox box = new()
    {
        FontFamily = Blocks.Mono,
        FontSize = 13,
        TextWrapping = TextWrapping.NoWrap,
        AcceptsReturn = true,
        IsSpellCheckEnabled = false,
        IsTextPredictionEnabled = false,
        ClipboardCopyFormat = RichEditClipboardFormat.PlainText,
        DisabledFormattingAccelerators = DisabledFormattingAccelerators.All,
    };
    private readonly TextBlock numbers = new()
    {
        FontFamily = Blocks.Mono,
        FontSize = 11,
        LineHeight = LineHeight,
        LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
        TextAlignment = TextAlignment.Right,
        Padding = new Thickness(0, Inset, 8, 0),
    };
    private readonly Border gutter = new() { HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(1), IsHitTestVisible = false };
    private readonly TranslateTransform scrolled = new();
    private readonly List<string> undoHistory = [];
    private readonly List<string> redoHistory = [];
    private string text = "";
    private int lines;
    /// <summary>Whether the box keeps a paragraph mark after the last line, which the text doesn't have.</summary>
    private bool hasFinalMark;
    private Edit lastEdit = Edit.Other;
    private long lastEditTime;
    private int lastEditEnd;
    private int colorings;
    private bool isComposing;

    /// <summary>The text changed, as you typed, undid or pasted.</summary>
    public event Action? TextChanged;

    /// <summary>How many stretches of the code the last coloring colored, for the self-check.</summary>
    public int ColoredTokens { get; private set; }

    public CodeEditor(string initial, Func<string, Task<JsonElement[][]>> highlight, string name)
    {
        this.highlight = highlight;
        AutomationProperties.SetName(box, name);
        // The editor's own history replaces the box's, which would undo the colors too.
        box.Document.UndoLimit = 0;
        numbers.RenderTransform = scrolled;
        gutter.Child = numbers;
        gutter.SizeChanged += (_, e) => gutter.Clip = new RectangleGeometry { Rect = new Rect(0, 0, e.NewSize.Width, e.NewSize.Height) };
        var root = new Grid();
        root.Children.Add(box);
        root.Children.Add(gutter);
        Content = root;

        Load(initial);
        box.TextChanged += (_, _) => OnTextChanged();
        box.PreviewKeyDown += OnKeyDown;
        box.Paste += OnPaste;
        box.TextCompositionStarted += (_, _) => isComposing = true;
        box.TextCompositionEnded += (_, _) =>
        {
            isComposing = false;
            ShowColors();
        };
        box.Loaded += (_, _) =>
        {
            // The numbers move with the code as it scrolls.
            if (ScrollViewerIn(box) is { } viewer)
            {
                viewer.ViewChanging += (_, e) => scrolled.Y = -e.NextView.VerticalOffset;
                viewer.ViewChanged += (_, _) => scrolled.Y = -viewer.VerticalOffset;
            }
        };
        // Light and dark mode color code differently; the palette changes first.
        ActualThemeChanged += (_, _) => DispatcherQueue.TryEnqueue(CrashReports.Reported.Queued(ShowColors));
    }

    /// <summary>The code, with line feeds. Setting it, as an example does, is one step to undo.</summary>
    public string Text
    {
        get => text;
        set
        {
            var changed = value.Replace("\r\n", "\n").Replace('\r', '\n');
            if (changed == text)
            {
                return;
            }
            Push(undoHistory, text);
            redoHistory.Clear();
            Restore(changed);
        }
    }

    /// <summary>
    /// Types `typed` at the end, as you would, then undoes it, and says how the text read back each
    /// time, for the self-check.
    /// </summary>
    public async Task<string> CheckTypingAsync(string typed)
    {
        var before = text;
        var tokens = ColoredTokens;
        box.Document.Selection.SetRange(text.Length, text.Length);
        box.Document.Selection.SetText(TextSetOptions.None, typed.Replace('\n', '\r'));
        box.Document.Selection.Collapse(false);
        await Task.Delay(500);
        var typing = text == before + typed ? "reads back" : $"reads back as {JsonSerializer.Serialize(text)}";
        var colors = $"{tokens} colored, then {ColoredTokens}";
        Undo();
        await Task.Delay(500);
        var undoing = text == before ? "restores it" : $"leaves {JsonSerializer.Serialize(text)}";
        return $"typing {typing} · {colors} · undo {undoing}";
    }

    /// <summary>Puts the cursor at `start`, selecting `length` characters, and scrolls it into view.</summary>
    public void Select(int start, int length)
    {
        var from = Math.Clamp(start, 0, text.Length);
        box.Document.Selection.SetRange(from, Math.Min(from + length, text.Length));
        box.Document.Selection.ScrollIntoView(PointOptions.None);
        box.Focus(FocusState.Programmatic);
    }

    private void Load(string initial)
    {
        text = initial.Replace("\r\n", "\n").Replace('\r', '\n');
        var paragraph = box.Document.GetDefaultParagraphFormat();
        paragraph.SetLineSpacing(LineSpacingRule.Exactly, LineSpacing);
        box.Document.SetDefaultParagraphFormat(paragraph);
        box.Document.SetText(TextSetOptions.None, text.Replace('\n', '\r'));
        box.Document.GetText(TextGetOptions.None, out var raw);
        hasFinalMark = raw.Length == text.Length + 1 && raw.EndsWith('\r');
        ShowLineNumbers();
        ShowColors();
    }

    /// <summary>The box counts a line's height in points, where the numbers beside it count pixels.</summary>
    private static float LineSpacing => (float)(LineHeight * 72 / 96);

    private string ReadText()
    {
        box.Document.GetText(TextGetOptions.None, out var raw);
        if (hasFinalMark && raw.EndsWith('\r'))
        {
            raw = raw[..^1];
        }
        return raw.Replace('\r', '\n');
    }

    private void OnTextChanged()
    {
        var changed = ReadText();
        // Coloring changes the box too, but not its text.
        if (changed == text)
        {
            return;
        }
        Record(text, changed);
        text = changed;
        Changed();
    }

    private void Changed()
    {
        ShowLineNumbers();
        ShowColors();
        TextChanged?.Invoke();
    }

    // MARK: Keys and pasting

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var control = IsDown(VirtualKey.Control);
        var shift = IsDown(VirtualKey.Shift);
        if (IsDown(VirtualKey.Menu))
        {
            return;
        }
        if (e.Key == VirtualKey.Tab && !control && !shift)
        {
            // Tab indents, as in a code editor, rather than moving to the next field.
            e.Handled = true;
            box.Document.Selection.SetText(TextSetOptions.None, "  ");
            box.Document.Selection.Collapse(false);
        }
        else if (control && e.Key == VirtualKey.Z && !shift)
        {
            e.Handled = true;
            Undo();
        }
        else if (control && (e.Key == VirtualKey.Y || (e.Key == VirtualKey.Z && shift)))
        {
            e.Handled = true;
            Redo();
        }
    }

    private static bool IsDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    /// <summary>Pastes text alone, so nothing pasted brings its own fonts or colors.</summary>
    private async void OnPaste(object sender, TextControlPasteEventArgs e)
    {
        e.Handled = true;
        var content = Clipboard.GetContent();
        if (!content.Contains(StandardDataFormats.Text))
        {
            return;
        }
        var pasted = await content.GetTextAsync();
        box.Document.Selection.SetText(TextSetOptions.None, pasted.Replace("\r\n", "\n").Replace('\n', '\r'));
        box.Document.Selection.Collapse(false);
    }

    // MARK: Undo

    /// <summary>Keeps the text from before a change. Typing or deleting in one place, without a pause, undoes in one step.</summary>
    private void Record(string before, string after)
    {
        var (start, removed, inserted) = Difference(before, after);
        var edit = removed == 0 && inserted == 1 && after[start] != '\n' ? Edit.Typing
            : removed == 1 && inserted == 0 ? Edit.Deleting
            : Edit.Other;
        var now = Environment.TickCount64;
        var continues = edit != Edit.Other && edit == lastEdit && now - lastEditTime < 1500
            && (start == lastEditEnd || (edit == Edit.Deleting && start + 1 == lastEditEnd));
        if (!continues)
        {
            Push(undoHistory, before);
        }
        redoHistory.Clear();
        lastEdit = edit;
        lastEditTime = now;
        lastEditEnd = start + inserted;
    }

    private void Undo()
    {
        if (undoHistory.Count == 0)
        {
            return;
        }
        Push(redoHistory, text);
        Restore(Pop(undoHistory));
    }

    private void Redo()
    {
        if (redoHistory.Count == 0)
        {
            return;
        }
        Push(undoHistory, text);
        Restore(Pop(redoHistory));
    }

    /// <summary>Shows text from the history, with the cursor at the end of what changed.</summary>
    private void Restore(string restored)
    {
        var (start, _, inserted) = Difference(text, restored);
        text = restored;
        lastEdit = Edit.Other;
        box.Document.SetText(TextSetOptions.None, restored.Replace('\n', '\r'));
        box.Document.Selection.SetRange(start + inserted, start + inserted);
        box.Document.Selection.ScrollIntoView(PointOptions.None);
        Changed();
    }

    private static void Push(List<string> history, string state)
    {
        history.Add(state);
        if (history.Count > HistoryLimit)
        {
            history.RemoveAt(0);
        }
    }

    private static string Pop(List<string> history)
    {
        var state = history[^1];
        history.RemoveAt(history.Count - 1);
        return state;
    }

    /// <summary>Where two texts start to differ, how much the first has there, and how much the second.</summary>
    private static (int Start, int Removed, int Inserted) Difference(string before, string after)
    {
        var start = 0;
        var shorter = Math.Min(before.Length, after.Length);
        while (start < shorter && before[start] == after[start])
        {
            start++;
        }
        var end = 0;
        while (end < shorter - start && before[^(end + 1)] == after[^(end + 1)])
        {
            end++;
        }
        return (start, before.Length - start - end, after.Length - start - end);
    }

    // MARK: Line numbers and colors

    private void ShowLineNumbers()
    {
        var count = text.Count(character => character == '\n') + 1;
        if (count == lines)
        {
            return;
        }
        lines = count;
        var list = new StringBuilder();
        for (var line = 1; line <= count; line++)
        {
            list.Append(line).Append('\n');
        }
        numbers.Text = list.ToString(0, list.Length - 1);
        // Room for the widest number, and for two digits at least.
        var width = Math.Max(2, count.ToString().Length) * 7 + 18;
        gutter.Width = width;
        box.Padding = new Thickness(width + 2, Inset, Inset, Inset);
        numbers.Foreground = Palette.Code("comment");
    }

    /// <summary>Colors the code again, once the core has read it. A coloring that comes after more typing is dropped.</summary>
    private async void ShowColors()
    {
        if (isComposing)
        {
            return;
        }
        var coloring = ++colorings;
        var colored = text;
        JsonElement[][] tokens;
        try
        {
            tokens = await highlight(colored);
        }
        catch (CoreProblem problem)
        {
            AppLog.Write($"couldn't color the script: {problem.Message}");
            return;
        }
        if (coloring != colorings || colored != text || isComposing)
        {
            return;
        }
        Paint(tokens);
    }

    private void Paint(JsonElement[][] tokens)
    {
        var document = box.Document;
        var plain = ((SolidColorBrush)Palette.Text).Color;
        document.BatchDisplayUpdates();
        try
        {
            // Everything starts plain, as text from anywhere might not be, then each token takes its color.
            var all = document.GetRange(0, text.Length + 1);
            Plain(all.CharacterFormat, plain);
            all.ParagraphFormat.SetLineSpacing(LineSpacingRule.Exactly, LineSpacing);
            all.ParagraphFormat.Alignment = ParagraphAlignment.Left;
            foreach (var token in tokens)
            {
                var location = token[0].GetInt32();
                var length = token[1].GetInt32();
                if (location < 0 || length <= 0 || location + length > text.Length)
                {
                    continue;
                }
                document.GetRange(location, location + length).CharacterFormat.ForegroundColor =
                    ((SolidColorBrush)Palette.Code(token[2].GetString())).Color;
            }
            // What you type next starts plain, until it's colored.
            if (document.Selection.Length == 0)
            {
                document.Selection.CharacterFormat.ForegroundColor = plain;
            }
            ColoredTokens = tokens.Length;
        }
        finally
        {
            document.ApplyDisplayUpdates();
        }
        numbers.Foreground = Palette.Code("comment");
    }

    private static void Plain(ITextCharacterFormat format, Windows.UI.Color color)
    {
        format.ForegroundColor = color;
        format.Bold = FormatEffect.Off;
        format.Italic = FormatEffect.Off;
        format.Underline = UnderlineType.None;
        format.Strikethrough = FormatEffect.Off;
    }

    private static ScrollViewer? ScrollViewerIn(DependencyObject parent)
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            var child = VisualTreeHelper.GetChild(parent, index);
            if (child is ScrollViewer viewer)
            {
                return viewer;
            }
            if (ScrollViewerIn(child) is { } found)
            {
                return found;
            }
        }
        return null;
    }
}
