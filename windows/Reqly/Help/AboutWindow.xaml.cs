using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;

namespace Reqly.Help;

/// <summary>
/// Help › About Reqly, as the Mac's Help › Reqly Help: Reqly's version, where to learn more, its
/// license, and the licenses of the open-source code inside it.
/// </summary>
public sealed partial class AboutWindow : Window
{
    /// <summary>The window's width at 100% scaling. It's as tall as what it shows.</summary>
    private const double WindowWidth = 460;

    private OpenSourceLicensesWindow? licenses;
    /// <summary>The license, while its dialog shows, for the self-check's picture of it.</summary>
    private ContentDialog? licenseDialog;

    public AboutWindow()
    {
        InitializeComponent();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Reqly.ico"));
        WindowLayout.MatchTitleBar(AppWindow);
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
        }
        // The .ico's first image is its smallest, so the large one comes from Reqly.png.
        AppIcon.Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Reqly.png")))
        {
            DecodePixelWidth = 80,
            DecodePixelType = DecodePixelType.Logical,
        };
        VersionText.Text = $"Version {AppInfo.Version}";
        CopyrightText.Text = AppInfo.Copyright;
        WebsiteLink.NavigateUri = AppInfo.Website;
        SourceCodeLink.NavigateUri = AppInfo.SourceCode;
        Closed += (_, _) => licenses?.Close();
    }

    /// <summary>The window's contents, for the self-check's picture of it.</summary>
    public UIElement View => Root;

    /// <summary>The license's dialog, while it shows.</summary>
    public UIElement? LicenseView => licenseDialog;

    /// <summary>Shows the window over another, the one About was chosen in, as tall as what it shows.</summary>
    public async Task OpenAsync(Window? over)
    {
        await WindowLayout.LoadedAsync(Root);
        var bounds = over is { } window
            ? new RectInt32(window.AppWindow.Position.X, window.AppWindow.Position.Y, window.AppWindow.Size.Width, window.AppWindow.Size.Height)
            : DisplayArea.Primary.WorkArea;
        var center = new PointInt32(bounds.X + bounds.Width / 2, bounds.Y + bounds.Height / 2);
        var scale = Tray.Screens.ScaleAt(center);
        Root.Measure(new Windows.Foundation.Size(WindowWidth, double.PositiveInfinity));
        AppWindow.ResizeClient(new SizeInt32((int)Math.Ceiling(WindowWidth * scale), (int)Math.Ceiling(Root.DesiredSize.Height * scale)));
        AppWindow.Move(new PointInt32(center.X - AppWindow.Size.Width / 2, center.Y - AppWindow.Size.Height / 2));
        Activate();
    }

    private async void OnViewLicenseClicked(object sender, RoutedEventArgs e) => await ShowLicenseAsync();

    /// <summary>The MIT License, in full.</summary>
    public async Task ShowLicenseAsync()
    {
        if (licenseDialog is not null)
        {
            return;
        }
        licenseDialog = new ContentDialog
        {
            Title = "MIT License",
            Content = new ScrollViewer
            {
                MaxHeight = 300,
                Content = new TextBlock
                {
                    Text = AppInfo.LicenseText is { } text
                        ? Paragraphs(text)
                        : "Reqly couldn't find its license text. It's the MIT License.",
                    TextWrapping = TextWrapping.Wrap,
                    IsTextSelectionEnabled = true,
                },
            },
            CloseButtonText = "Close",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = Root.XamlRoot,
            Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"],
        };
        try
        {
            await licenseDialog.ShowAsync();
        }
        finally
        {
            licenseDialog = null;
        }
    }

    /// <summary>
    /// The license with each paragraph on one line, which the dialog wraps at its width. The file
    /// breaks its lines at 80 characters, wider than the dialog, so they'd wrap a second time.
    /// </summary>
    private static string Paragraphs(string text) =>
        System.Text.RegularExpressions.Regex.Replace(text.ReplaceLineEndings("\n").Trim(), @"(?<=\S)\n(?=\S)", " ");

    /// <summary>Closes the license's dialog, if it shows.</summary>
    public void HideLicense() => licenseDialog?.Hide();

    private void OnOpenSourceLicensesClicked(object sender, RoutedEventArgs e) => ShowOpenSourceLicenses();

    /// <summary>Opens the open-source licenses, or brings them forward.</summary>
    public OpenSourceLicensesWindow ShowOpenSourceLicenses()
    {
        if (licenses is null)
        {
            licenses = new OpenSourceLicensesWindow();
            licenses.Closed += (_, _) => licenses = null;
            _ = licenses.OpenAsync(this);
        }
        else
        {
            licenses.Activate();
        }
        return licenses;
    }

    /// <summary>What the window shows, and how big it is, for the self-check.</summary>
    public string Describe() =>
        $"{VersionText.Text} · {CopyrightText.Text} · {AppWindow.ClientSize.Width}×{AppWindow.ClientSize.Height} for contents {Contents.ActualWidth:0}×{Contents.ActualHeight:0}";
}
