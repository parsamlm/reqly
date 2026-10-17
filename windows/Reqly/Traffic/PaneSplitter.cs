using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace Reqly.Traffic;

/// <summary>
/// The line between the list and the details: drag it to give the details more or less room. The
/// details column's own minimum and maximum widths bound it.
/// </summary>
public sealed partial class PaneSplitter : Grid
{
    private double startX;
    private double startWidth;
    private bool isDragging;

    /// <summary>The column to the splitter's right, whose width it changes.</summary>
    public ColumnDefinition? Target { get; set; }

    public PaneSplitter()
    {
        // Transparent, so the whole strip takes the pointer.
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
        PointerPressed += OnPointerPressed;
        PointerMoved += OnPointerMoved;
        PointerReleased += (_, args) => EndDrag(args);
        PointerCaptureLost += (_, _) => isDragging = false;
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs args)
    {
        if (Target is null)
        {
            return;
        }
        isDragging = CapturePointer(args.Pointer);
        startX = args.GetCurrentPoint(null).Position.X;
        startWidth = Target.ActualWidth;
        args.Handled = true;
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs args)
    {
        if (!isDragging || Target is null)
        {
            return;
        }
        // Dragging left widens the details.
        var width = startWidth - (args.GetCurrentPoint(null).Position.X - startX);
        Target.Width = new GridLength(Math.Clamp(width, Target.MinWidth, Target.MaxWidth));
        args.Handled = true;
    }

    private void EndDrag(PointerRoutedEventArgs args)
    {
        if (isDragging)
        {
            ReleasePointerCapture(args.Pointer);
            isDragging = false;
        }
    }
}
