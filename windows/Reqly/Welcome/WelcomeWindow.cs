using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Reqly.Https;
using Reqly.Inspector;
using Windows.Graphics;

namespace Reqly.Welcome;

/// <summary>
/// The first-run guide, as the Mac's: what capturing does, then setting up the certificate and
/// choosing the hosts to decrypt. It opens once, the first time Reqly does, and from the Help menu after.
/// </summary>
public sealed partial class WelcomeWindow : Window
{
    private enum Step
    {
        Done,
        Current,
        Upcoming,
    }

    private readonly MainWindow main;
    private readonly HttpsModel https;
    private readonly StackPanel steps = new();
    private readonly Button finish = new();
    private readonly Grid root = new() { Background = Blocks.Resource("ApplicationPageBackgroundThemeBrush") };

    public WelcomeWindow(MainWindow main, HttpsModel https)
    {
        this.main = main;
        this.https = https;
        Title = "Welcome to Reqly";
        AppWindow.Resize(new SizeInt32(760, 640));
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Reqly.ico"));
        WindowLayout.MatchTitleBar(AppWindow);
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var top = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center, Padding = new Thickness(0, 36, 0, 24) };
        var icon = new Image
        {
            // The .ico's first image is its smallest, so the large one comes from Reqly.png.
            Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Reqly.png")))
            {
                DecodePixelWidth = 92,
                DecodePixelType = DecodePixelType.Logical,
            },
            Width = 92,
            Height = 92,
            Margin = new Thickness(0, 0, 0, 8),
        };
        top.Children.Add(icon);
        top.Children.Add(new TextBlock { Text = "Welcome to Reqly", Style = (Style)Application.Current.Resources["TitleTextBlockStyle"], HorizontalAlignment = HorizontalAlignment.Center });
        top.Children.Add(new TextBlock { Text = "See what your PC's apps send and receive.", Foreground = Blocks.Resource("TextFillColorSecondaryBrush"), HorizontalAlignment = HorizontalAlignment.Center });
        root.Children.Add(top);
        var card = new Border
        {
            Child = steps,
            CornerRadius = new CornerRadius(12),
            BorderThickness = new Thickness(1),
            BorderBrush = Blocks.Resource("CardStrokeColorDefaultBrush"),
            Background = Blocks.Resource("CardBackgroundFillColorDefaultBrush"),
            Margin = new Thickness(44, 0, 44, 0),
            VerticalAlignment = VerticalAlignment.Top,
        };
        Grid.SetRow(card, 1);
        root.Children.Add(card);
        var footer = new Grid { Padding = new Thickness(24, 16, 24, 16), BorderThickness = new Thickness(0, 1, 0, 0), BorderBrush = Blocks.Resource("DividerStrokeColorDefaultBrush") };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.Children.Add(new TextBlock { Text = "You can change all of this later in Settings.", Foreground = Blocks.Resource("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center });
        finish.Click += (_, _) => Close();
        Grid.SetColumn(finish, 1);
        footer.Children.Add(finish);
        Grid.SetRow(footer, 2);
        root.Children.Add(footer);
        Content = root;
        main.CaptureChanged += Show;
        https.Changed += Show;
        Closed += (_, _) =>
        {
            main.CaptureChanged -= Show;
            https.Changed -= Show;
        };
        Show();
    }

    /// <summary>The window's contents, for the self-check's picture of it.</summary>
    public UIElement View => root;

    private int HostCount => https.Hosts.Entries.Count(entry => entry.IsOn);

    private bool HasHosts => https.Hosts.IncludesEveryHost || HostCount > 0;

    /// <summary>The first step that isn't done: capturing, then the certificate, then the hosts. None once all are.</summary>
    private int? CurrentStep => main.CapturingPort is null ? 1 : !https.IsTrusted ? 2 : !HasHosts ? 3 : null;

    private Step Pending(int number) => CurrentStep == number ? Step.Current : Step.Upcoming;

    /// <summary>What the guide shows, for the self-check.</summary>
    public string Describe() => $"next: {(CurrentStep is int step ? $"step {step}" : "none")} · {finish.Content}";

    private void Show()
    {
        steps.Children.Clear();
        steps.Children.Add(CaptureStep());
        steps.Children.Add(Divider());
        steps.Children.Add(CertificateStep());
        steps.Children.Add(Divider());
        steps.Children.Add(HostsStep());
        var isFinished = CurrentStep is null;
        finish.Content = isFinished ? "Get started" : "Skip for now";
        finish.Style = (Style)Application.Current.Resources[isFinished ? "AccentButtonStyle" : "DefaultButtonStyle"];
    }

    private UIElement CaptureStep()
    {
        const string title = "Capture your PC's traffic";
        var detail = main.SetsSystemProxy
            ? "While capturing, Reqly is your PC's proxy. Your network settings come back when you stop."
            : $"This copy of Reqly captures the apps you point at 127.0.0.1, port {main.Port}.";
        if (main.CapturingPort is not null)
        {
            return Row(1, Step.Done, title, detail, null, Tag("Capturing"));
        }
        if (main.IsCaptureBusy)
        {
            return Row(1, Pending(1), title, detail, null, new ProgressRing { Width = 16, Height = 16, IsActive = true });
        }
        return Row(1, Pending(1), title, detail, main.CaptureProblem, StepButton(
            main.CaptureProblem is null ? "Start capturing" : "Try again", CurrentStep == 1, () => _ = main.StartCapturingFromDevicesAsync()));
    }

    private UIElement CertificateStep()
    {
        const string title = "Install the Reqly certificate";
        const string detail = "To read HTTPS traffic, your PC needs to trust a certificate that Reqly creates just for you. It never leaves this PC.";
        switch (https.Status)
        {
            case HttpsModel.Phase.Trusted:
                return Row(2, Step.Done, title, detail, null, Tag("Installed"));
            case HttpsModel.Phase.Checking or HttpsModel.Phase.Working:
                var working = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                working.Children.Add(new ProgressRing { Width = 16, Height = 16, IsActive = true });
                if (https.Message is { } message)
                {
                    working.Children.Add(new TextBlock { Text = message, Foreground = Blocks.Resource("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center });
                }
                return Row(2, Pending(2), title, detail, null, working);
            case HttpsModel.Phase.Failed:
                return Row(2, Pending(2), title, detail, https.Message, StepButton("Try again", CurrentStep == 2, () => _ = https.SetUpAsync()));
            default:
                var label = https.Status == HttpsModel.Phase.NotTrusted ? "Trust certificate…" : "Install certificate…";
                return Row(2, Pending(2), title, detail + " Windows asks you to confirm.", null, StepButton(label, CurrentStep == 2, () => _ = https.SetUpAsync()));
        }
    }

    private UIElement HostsStep()
    {
        const string title = "Choose hosts to decrypt";
        const string detail = "Decrypt only the hosts you care about. Everything else stays encrypted.";
        if (!https.IsTrusted)
        {
            // Hosts are decrypted only with the certificate, so this waits for step 2.
            return Row(3, Step.Upcoming, title, detail, null, null);
        }
        if (HasHosts)
        {
            var count = https.Hosts.IncludesEveryHost ? "All hosts" : HostCount == 1 ? "1 host" : $"{HostCount} hosts";
            var link = Blocks.Link(count, () => main.ShowSettings(Settings.SettingsWindow.Pane.Https));
            ToolTipService.SetToolTip(link, "Shows the hosts in Settings");
            return Row(3, Step.Done, title, detail, null, link);
        }
        return Row(3, Pending(3), title, detail, null, StepButton("Choose hosts…", CurrentStep == 3, () => main.ShowSettings(Settings.SettingsWindow.Pane.Https)));
    }

    /// <summary>A step's button: an accent one on the step the guide points at, a plain one on the others, so they can be done in any order.</summary>
    private static Button StepButton(string title, bool isProminent, Action action)
    {
        var button = new Button { Content = title };
        if (isProminent)
        {
            button.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        }
        button.Click += (_, _) => action();
        return button;
    }

    private static TextBlock Tag(string text) => new() { Text = text, Foreground = Blocks.Resource("TextFillColorSecondaryBrush"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };

    private static Border Divider() => new() { Height = 1, Background = Blocks.Resource("DividerStrokeColorDefaultBrush") };

    /// <summary>One step: its number, or a check once it's done, what it's about, and its action.</summary>
    private static Grid Row(int number, Step state, string title, string detail, string? problem, UIElement? action)
    {
        var row = new Grid { ColumnSpacing = 14, Padding = new Thickness(18, 16, 18, 16) };
        if (state == Step.Current)
        {
            row.Background = new SolidColorBrush((Windows.UI.Color)Application.Current.Resources["SystemAccentColor"]) { Opacity = 0.1 };
        }
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var badge = new Grid { Width = 26, Height = 26, VerticalAlignment = VerticalAlignment.Center };
        var circle = new Microsoft.UI.Xaml.Shapes.Ellipse { StrokeThickness = state == Step.Upcoming ? 1.5 : 2 };
        switch (state)
        {
            case Step.Done:
                circle.Fill = Blocks.Resource("AccentFillColorDefaultBrush");
                badge.Children.Add(circle);
                badge.Children.Add(new FontIcon { Glyph = "", FontSize = 12, Foreground = Blocks.Resource("TextOnAccentFillColorPrimaryBrush") });
                break;
            default:
                circle.Stroke = Blocks.Resource(state == Step.Current ? "AccentFillColorDefaultBrush" : "ControlStrongStrokeColorDefaultBrush");
                badge.Children.Add(circle);
                badge.Children.Add(new TextBlock
                {
                    Text = number.ToString(System.Globalization.CultureInfo.CurrentCulture),
                    FontSize = 12,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                    Foreground = Blocks.Resource(state == Step.Current ? "TextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush"),
                });
                break;
        }
        row.Children.Add(badge);
        var words = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock { Text = title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        words.Children.Add(new TextBlock { Text = detail, TextWrapping = TextWrapping.Wrap, Foreground = Blocks.Resource("TextFillColorSecondaryBrush") });
        if (problem is not null)
        {
            words.Children.Add(new TextBlock { Text = problem, TextWrapping = TextWrapping.Wrap, Foreground = Blocks.Resource("SystemFillColorCautionBrush") });
        }
        var progress = state switch { Step.Done => "Done", Step.Current => "Next", _ => "Later" };
        AutomationProperties.SetName(words, $"Step {number}, {progress}: {title}. {detail}{(problem is null ? "" : $" {problem}")}");
        Grid.SetColumn(words, 1);
        row.Children.Add(words);
        if (action is FrameworkElement element)
        {
            element.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(element, 2);
            row.Children.Add(element);
        }
        return row;
    }
}
