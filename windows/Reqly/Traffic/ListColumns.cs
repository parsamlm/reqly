using System.ComponentModel;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace Reqly.Traffic;

/// <summary>
/// The list's column widths, as on the Mac: drag the edge of a column's title to change it, and
/// every row follows. The Request column takes the room the others leave.
/// </summary>
public sealed partial class ListColumns : INotifyPropertyChanged
{
    /// <summary>The columns you can change, in order, with the width each starts at.</summary>
    public static readonly (string Name, double Width)[] Columns =
        [("Status", 70), ("Method", 60), ("App", 100), ("Time", 80), ("Duration", 64), ("Size", 58)];

    /// <summary>The widths every window's list uses. It comes after the columns, which it starts from.</summary>
    public static ListColumns Shared { get; } = new();

    public const double MinWidth = 44;

    private readonly double[] widths = [.. Columns.Select(column => column.Width)];

    public event PropertyChangedEventHandler? PropertyChanged;

    public GridLength Status => new(widths[0]);
    public GridLength Method => new(widths[1]);
    public GridLength App => new(widths[2]);
    public GridLength Time => new(widths[3]);
    public GridLength Duration => new(widths[4]);
    public GridLength Size => new(widths[5]);

    public double this[int column] => widths[column];

    /// <summary>The widths, for keeping in Settings.</summary>
    public double[] Widths => [.. widths];

    public void Set(int column, double width)
    {
        var bounded = Math.Clamp(width, MinWidth, 600);
        if (Math.Abs(bounded - widths[column]) < 0.5)
        {
            return;
        }
        widths[column] = bounded;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(Columns[column].Name));
    }

    /// <summary>Widths kept in Settings, when there are as many as there are columns.</summary>
    public void Use(double[]? saved)
    {
        if (saved?.Length != widths.Length)
        {
            return;
        }
        for (var column = 0; column < widths.Length; column++)
        {
            Set(column, saved[column]);
        }
    }
}

/// <summary>The edge of a column's title, which you drag to make the column wider or narrower.</summary>
public sealed partial class ColumnGrip : Grid
{
    private double startX;
    private double startWidth;
    private bool isDragging;

    /// <summary>The column whose right edge this is, in <see cref="ListColumns.Columns"/>.</summary>
    public int Column { get; set; }

    public ColumnGrip()
    {
        Width = 8;
        HorizontalAlignment = HorizontalAlignment.Right;
        // Over the gap between this column and the next, so either side's edge takes the pointer.
        Margin = new Thickness(0, -6, -8, -6);
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
        PointerPressed += (_, args) =>
        {
            isDragging = CapturePointer(args.Pointer);
            startX = args.GetCurrentPoint(null).Position.X;
            startWidth = ListColumns.Shared[Column];
            args.Handled = true;
        };
        PointerMoved += (_, args) =>
        {
            if (isDragging)
            {
                ListColumns.Shared.Set(Column, startWidth + args.GetCurrentPoint(null).Position.X - startX);
                args.Handled = true;
            }
        };
        PointerReleased += (_, args) =>
        {
            isDragging = false;
            ReleasePointerCapture(args.Pointer);
        };
        PointerCaptureLost += (_, _) => isDragging = false;
        // Double-clicking an edge puts the column back as it started.
        DoubleTapped += (_, _) => ListColumns.Shared.Set(Column, ListColumns.Columns[Column].Width);
    }
}
