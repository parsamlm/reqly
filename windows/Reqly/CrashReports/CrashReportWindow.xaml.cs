using System.Diagnostics;
using System.Globalization;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.System;

namespace Reqly.CrashReports;

/// <summary>
/// Asks whether to report Reqly's last crash, and shows what the report says, as the Mac does.
/// Reporting opens a new issue in your browser, filled in, which you submit yourself.
/// </summary>
public sealed partial class CrashReportWindow : Window
{
    /// <summary>The window's width at 100% scaling. It's as tall as what it shows.</summary>
    private const double WindowWidth = 620;

    private readonly CrashReporter.Report report;
    /// <summary>Whether reporting opens the browser, which a test run's doesn't.</summary>
    private readonly bool opensBrowser;

    internal CrashReportWindow(CrashReporter.Report report, bool opensBrowser)
    {
        this.report = report;
        this.opensBrowser = opensBrowser;
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
        var local = report.Date.ToLocalTime();
        Explanation.Text = string.Create(CultureInfo.CurrentCulture,
            $"It happened on {local:D} at {local:t}. You can report it on GitHub, so it gets fixed. Reqly opens a new issue in your browser with the details below. Add what you were doing, and attach the full report if you like, then submit it yourself. Nothing is sent until you do.");
        Details.Text = report.Body;
        Root.KeyDown += OnKeyDown;
    }

    /// <summary>The window's contents, for the self-check's picture of it.</summary>
    public UIElement View => Root;

    /// <summary>The new issue that reporting opens, filled in.</summary>
    public Uri IssueLink => CrashReporter.IssueUrl(report.Title, report.Body);

    /// <summary>Shows the window over Reqly's, as tall as what it shows.</summary>
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

    private void OnReportClicked(object sender, RoutedEventArgs e) => Report();

    /// <summary>Opens the new issue in the browser, as Report on GitHub does, and closes.</summary>
    public void Report()
    {
        var link = IssueLink;
        AppLog.Write($"reporting the crash: a new issue, {link.AbsoluteUri.Length:N0} characters long");
        if (opensBrowser)
        {
            CrashReporter.Open(link);
        }
        Close();
    }

    private void OnDontReportClicked(object sender, RoutedEventArgs e) => Close();

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Escape)
        {
            e.Handled = true;
            Close();
        }
    }

    /// <summary>Shows the full report in File Explorer, to attach it to the issue.</summary>
    private void OnShowClicked(object sender, RoutedEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{report.File}\"") { UseShellExecute = true });
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            AppLog.Write($"couldn't show the crash report: {error.Message}");
        }
    }

    private void OnCopyClicked(object sender, RoutedEventArgs e)
    {
        var package = new DataPackage();
        package.SetText(report.Body);
        Clipboard.SetContent(package);
        CopyButton.Content = "Copied";
    }

    /// <summary>What the window shows, and how big it is, for the self-check.</summary>
    public string Describe() =>
        $"{report.Title} · {report.Body.Split('\n').Length} lines · the issue's link {IssueLink.AbsoluteUri.Length:N0} characters · " +
        $"full report {Path.GetFileName(report.File)} · {AppWindow.ClientSize.Width}×{AppWindow.ClientSize.Height} for contents {Contents.ActualWidth:0}×{Contents.ActualHeight:0}";

    /// <summary>The issue's text, for the self-check.</summary>
    public string Body => report.Body;
}
