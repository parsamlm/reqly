using System.Collections;
using System.Text;
using Microsoft.UI.Xaml.Controls;
using Reqly.Traffic;

namespace Reqly.Inspector;

/// <summary>
/// A body's bytes, unpacked. The list makes only the rows it shows, so a big body stays quick.
/// Selected rows copy as hex with Ctrl+C, as "1F 8B …".
/// </summary>
public sealed partial class HexView : UserControl
{
    private readonly byte[] bytes;

    public HexView(byte[] bytes, int total, double maxHeight)
    {
        this.bytes = bytes;
        InitializeComponent();
        Frame.Background = Palette.CodeBackground;
        Rows.MaxHeight = maxHeight;
        Rows.ItemsSource = new HexRows(bytes);
        Total.Text = Bytes(total) + (bytes.Length < total ? $" · showing the first {Bytes(bytes.Length)}" : "");
        Rows.SelectionChanged += (_, _) =>
        {
            var rows = Rows.SelectedRanges.Sum(range => (int)range.Length);
            Selected.Text = rows == 0 ? "" : $"{Bytes(Math.Min(rows * 16, bytes.Length))} selected";
        };
        Rows.KeyDown += (_, args) =>
        {
            var isControl = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control)
                .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            if (isControl && args.Key == Windows.System.VirtualKey.C)
            {
                args.Handled = true;
                Copy?.Invoke(SelectedHex());
            }
        };
    }

    /// <summary>Puts text where Copy puts it.</summary>
    public Action<string>? Copy { get; set; }

    /// <summary>The selected rows' bytes, or all of them, as hex pairs.</summary>
    public string SelectedHex()
    {
        var picked = Rows.SelectedRanges.SelectMany(range => Enumerable.Range(range.FirstIndex, (int)range.Length)).ToList();
        var rows = picked.Count == 0 ? Enumerable.Range(0, (bytes.Length + 15) / 16) : picked.Order();
        var text = new StringBuilder();
        foreach (var row in rows)
        {
            for (var at = row * 16; at < Math.Min(bytes.Length, row * 16 + 16); at++)
            {
                text.Append(text.Length > 0 ? " " : "").Append(bytes[at].ToString("X2"));
            }
        }
        return text.ToString();
    }

    private static string Bytes(int count) => count == 1 ? "1 byte" : $"{count:N0} bytes";
}

/// <summary>A row of bytes: where it starts, the bytes, and their characters, with a dot for each that isn't one.</summary>
public sealed class HexRow(string offset, string hex, string characters)
{
    public string Offset { get; } = offset;
    public string Hex { get; } = hex;
    public string Characters { get; } = characters;

    public override string ToString() => $"{Offset} {Hex} {Characters}";
}

/// <summary>The rows, made as the list asks for them, so a million of them cost nothing until shown.</summary>
public sealed class HexRows(byte[] bytes) : IList
{
    private readonly int digits = bytes.Length > 0xFFFFFF ? 8 : 6;

    public int Count => (bytes.Length + 15) / 16;

    public object? this[int index]
    {
        get
        {
            var start = index * 16;
            var hex = new StringBuilder(49);
            var characters = new StringBuilder(16);
            for (var at = start; at < start + 16; at++)
            {
                if (at == start + 8)
                {
                    hex.Append(' ');
                }
                if (at < bytes.Length)
                {
                    hex.Append(bytes[at].ToString("X2")).Append(' ');
                    characters.Append(bytes[at] is >= 0x20 and <= 0x7E ? (char)bytes[at] : '.');
                }
                else
                {
                    hex.Append("   ");
                }
            }
            return new HexRow(start.ToString(digits == 8 ? "X8" : "X6"), hex.ToString().TrimEnd(), characters.ToString());
        }
        set => throw new NotSupportedException();
    }

    public bool IsFixedSize => true;
    public bool IsReadOnly => true;
    public bool IsSynchronized => false;
    public object SyncRoot => this;
    public int Add(object? value) => throw new NotSupportedException();
    public void Clear() => throw new NotSupportedException();
    public bool Contains(object? value) => false;
    public int IndexOf(object? value) => -1;
    public void Insert(int index, object? value) => throw new NotSupportedException();
    public void Remove(object? value) => throw new NotSupportedException();
    public void RemoveAt(int index) => throw new NotSupportedException();
    public void CopyTo(Array array, int index)
    {
        for (var row = 0; row < Count; row++)
        {
            array.SetValue(this[row], index + row);
        }
    }

    public IEnumerator GetEnumerator()
    {
        for (var row = 0; row < Count; row++)
        {
            yield return this[row];
        }
    }
}
