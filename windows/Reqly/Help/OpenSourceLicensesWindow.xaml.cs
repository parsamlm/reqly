using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

namespace Reqly.Help;

/// <summary>
/// The licenses of the open-source packages inside Reqly, in full, as on the Mac: the packages on
/// the left, and the chosen one's license and notices on the right, from the list that
/// <c>tools/acknowledgements.py</c> writes.
/// </summary>
public sealed partial class OpenSourceLicensesWindow : Window
{
    /// <summary>
    /// The window's size at 100% scaling. License files wrap at about 80 characters, and the text
    /// column fits that, so their lines don't wrap a second time.
    /// </summary>
    private const double WindowWidth = 900;
    private const double WindowHeight = 640;

    private readonly IReadOnlyList<OpenSourcePackage> packages = AppInfo.OpenSourcePackages;

    public OpenSourceLicensesWindow()
    {
        InitializeComponent();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Reqly.ico"));
        WindowLayout.MatchTitleBar(AppWindow);
        if (packages.Count == 0)
        {
            Box.Visibility = Visibility.Collapsed;
            MissingText.Visibility = Visibility.Visible;
            return;
        }
        Packages.ItemsSource = packages;
        Packages.SelectedIndex = 0;
    }

    /// <summary>The window's contents, for the self-check's picture of it.</summary>
    public UIElement View => Root;

    /// <summary>Shows the window over another, the one it was opened from, inside the screen.</summary>
    public Task OpenAsync(Window over)
    {
        var center = new PointInt32(over.AppWindow.Position.X + over.AppWindow.Size.Width / 2, over.AppWindow.Position.Y + over.AppWindow.Size.Height / 2);
        var scale = Tray.Screens.ScaleAt(center);
        AppWindow.ResizeClient(new SizeInt32((int)Math.Ceiling(WindowWidth * scale), (int)Math.Ceiling(WindowHeight * scale)));
        var work = DisplayArea.GetFromPoint(center, DisplayAreaFallback.Nearest).WorkArea;
        var size = AppWindow.Size;
        AppWindow.Move(new PointInt32(
            Math.Clamp(center.X - size.Width / 2, work.X, Math.Max(work.X, work.X + work.Width - size.Width)),
            Math.Clamp(center.Y - size.Height / 2, work.Y, Math.Max(work.Y, work.Y + work.Height - size.Height))));
        Activate();
        return Task.CompletedTask;
    }

    private void OnPackageChosen(object sender, SelectionChangedEventArgs e)
    {
        if (Packages.SelectedItem is OpenSourcePackage package)
        {
            Show(package);
        }
        else if (e.RemovedItems.FirstOrDefault() is OpenSourcePackage previous)
        {
            // The list always has a package chosen.
            Packages.SelectedItem = previous;
        }
    }

    /// <summary>A package's version and link, then its license and notices.</summary>
    private void Show(OpenSourcePackage package)
    {
        Details.Children.Clear();
        var secondary = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        var heading = new StackPanel { Spacing = 4 };
        heading.Children.Add(new TextBlock { Text = package.Name, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], IsTextSelectionEnabled = true });
        heading.Children.Add(new TextBlock { Text = $"Version {package.Version} · {package.License}", Foreground = secondary, IsTextSelectionEnabled = true });
        if (Uri.TryCreate(package.Url, UriKind.Absolute, out var url))
        {
            heading.Children.Add(new HyperlinkButton { Content = url.Host + url.AbsolutePath.TrimEnd('/'), NavigateUri = url, Padding = new Thickness(0) });
        }
        Details.Children.Add(heading);
        foreach (var notice in package.Notices)
        {
            var part = new StackPanel { Spacing = 6 };
            part.Children.Add(new TextBlock { Text = notice.Title, FontWeight = FontWeights.SemiBold, IsTextSelectionEnabled = true });
            part.Children.Add(new TextBlock { Text = notice.Text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
            Details.Children.Add(part);
        }
        // Each package starts at the top.
        Scroller.ChangeView(null, 0, null, disableAnimation: true);
    }

    // MARK: For the self-check

    /// <summary>Chooses a package, as clicking it in the list does.</summary>
    public void Choose(string name)
    {
        if (packages.FirstOrDefault(package => package.Name == name) is { } package)
        {
            Packages.SelectedItem = package;
            Packages.ScrollIntoView(package);
        }
    }

    /// <summary>What the window shows, for the self-check.</summary>
    public string Describe()
    {
        if (Packages.SelectedItem is not OpenSourcePackage chosen)
        {
            return $"{packages.Count} packages, none chosen";
        }
        var characters = chosen.Notices.Sum(notice => notice.Text.Length);
        return $"{packages.Count} packages · {chosen.Name} {chosen.Version}, {chosen.License}, {chosen.Notices.Length} notices " +
            $"({characters:N0} characters) · {AppWindow.ClientSize.Width}×{AppWindow.ClientSize.Height}, its text column {Scroller.ActualWidth:0} wide";
    }
}
