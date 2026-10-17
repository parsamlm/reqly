using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;

namespace Reqly;

/// <summary>For Reqly's windows: their title bars, and opening at the size of what they show.</summary>
internal static class WindowLayout
{
    /// <summary>
    /// Has a window's title bar follow Reqly's light or dark mode, as its contents do. Windows
    /// draws an app's title bar light, even in dark mode, unless the app asks for its mode. The
    /// main window draws its own.
    /// </summary>
    public static void MatchTitleBar(AppWindow window) =>
        window.TitleBar.PreferredTheme = App.Current.Theme switch
        {
            "light" => TitleBarTheme.Light,
            "dark" => TitleBarTheme.Dark,
            _ => TitleBarTheme.UseDefaultAppMode,
        };

    /// <summary>
    /// Waits for an element's first layout, the first time its window opens: until then its
    /// controls have no templates, and it measures shorter than it shows.
    /// </summary>
    public static async Task LoadedAsync(FrameworkElement element)
    {
        if (element.IsLoaded)
        {
            return;
        }
        var loaded = new TaskCompletionSource();
        void OnLoaded(object sender, RoutedEventArgs e) => loaded.TrySetResult();
        element.Loaded += OnLoaded;
        // WinUI lays out a window's contents before it first shows, but in case it waits for that.
        await Task.WhenAny(loaded.Task, Task.Delay(500));
        element.Loaded -= OnLoaded;
    }
}
