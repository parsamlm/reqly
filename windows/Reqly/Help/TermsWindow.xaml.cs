using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;

namespace Reqly.Help;

/// <summary>
/// The first thing Reqly shows, the first time it opens: Reqly's license, and Microsoft's terms
/// for the software from Microsoft that comes with it, which you agree to before using Reqly, as
/// those terms ask. Quitting, or closing the window, leaves Reqly unused.
/// </summary>
public sealed partial class TermsWindow : Window
{
    /// <summary>The window's width at 100% scaling. It's as tall as what it shows.</summary>
    private const double WindowWidth = 520;

    private bool hasAnswered;
    /// <summary>A text it shows, while its dialog shows.</summary>
    private ContentDialog? dialog;

    public TermsWindow()
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
        AppIcon.Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Reqly.png")))
        {
            DecodePixelWidth = 56,
            DecodePixelType = DecodePixelType.Logical,
        };
        foreach (var part in Terms.Parts)
        {
            PartsList.Children.Add(PartLine(part));
        }
        Closed += (_, _) =>
        {
            if (!hasAnswered)
            {
                hasAnswered = true;
                Declined?.Invoke();
            }
        };
    }

    /// <summary>You agreed. Reqly opens, and then this window closes.</summary>
    public event Action? Agreed;

    /// <summary>You quit, or closed the window.</summary>
    public event Action? Declined;

    /// <summary>The window's contents, for the self-check's picture of it.</summary>
    public UIElement View => Root;

    /// <summary>Shows the window in the middle of the main screen, as tall as what it shows.</summary>
    public async Task OpenAsync()
    {
        await WindowLayout.LoadedAsync(Root);
        var work = DisplayArea.Primary.WorkArea;
        var center = new PointInt32(work.X + work.Width / 2, work.Y + work.Height / 2);
        var scale = Tray.Screens.ScaleAt(center);
        Root.Measure(new Windows.Foundation.Size(WindowWidth, double.PositiveInfinity));
        AppWindow.ResizeClient(new SizeInt32((int)Math.Ceiling(WindowWidth * scale), (int)Math.Ceiling(Root.DesiredSize.Height * scale)));
        AppWindow.Move(new PointInt32(center.X - AppWindow.Size.Width / 2, center.Y - AppWindow.Size.Height / 2));
        Activate();
    }

    /// <summary>A part of Microsoft's software, its name a link to its terms, and what Reqly uses it for.</summary>
    private TextBlock PartLine(Terms.Part part)
    {
        var link = new Hyperlink();
        link.Inlines.Add(new Run { Text = part.Name });
        if (part.Page is { } page)
        {
            link.NavigateUri = page;
        }
        else
        {
            link.Click += async (_, _) => await ShowTextAsync($"Microsoft's terms for {part.Name}", Terms.Text(part) ?? "Reqly couldn't find these terms.", reflows: false);
        }
        var line = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(12, 0, 0, 0) };
        line.Inlines.Add(new Run { Text = "• " });
        line.Inlines.Add(link);
        line.Inlines.Add(new Run { Text = $", {part.Use}" });
        return line;
    }

    private async void OnLicenseClicked(object sender, RoutedEventArgs e) =>
        await ShowTextAsync("MIT License", AppInfo.LicenseText ?? "Reqly couldn't find its license text. It's the MIT License.", reflows: true);

    /// <summary>
    /// A text in full, in a dialog over the window. Reqly's license, whose file breaks its lines
    /// at 80 characters, shows each paragraph on one line, which the dialog wraps at its width.
    /// </summary>
    private async Task ShowTextAsync(string title, string text, bool reflows)
    {
        if (dialog is not null)
        {
            return;
        }
        dialog = new ContentDialog
        {
            Title = title,
            Content = new ScrollViewer
            {
                MaxHeight = 360,
                Content = new TextBlock
                {
                    Text = reflows
                        ? System.Text.RegularExpressions.Regex.Replace(text.ReplaceLineEndings("\n").Trim(), @"(?<=\S)\n(?=\S)", " ")
                        : text,
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
            await dialog.ShowAsync();
        }
        finally
        {
            dialog = null;
        }
    }

    private void OnAgreeClicked(object sender, RoutedEventArgs e) => Agree();

    /// <summary>Agrees, as the Agree button does: Reqly opens first, so it never runs out of windows, then this one closes.</summary>
    public void Agree()
    {
        if (hasAnswered)
        {
            return;
        }
        hasAnswered = true;
        Agreed?.Invoke();
        Close();
    }

    private void OnQuitClicked(object sender, RoutedEventArgs e) => Close();

    /// <summary>What the window shows, for the self-check.</summary>
    public string Describe() =>
        $"{Terms.Parts.Length} parts ({string.Join(", ", Terms.Parts.Select(part => part.File is not null && Terms.Text(part) is { } text ? $"{part.Name}, {text.Length:N0} characters" : $"{part.Name}, {part.Page}"))}) · " +
        $"{AppWindow.ClientSize.Width}×{AppWindow.ClientSize.Height} for contents {Contents.ActualWidth:0}×{Contents.ActualHeight:0}";
}
