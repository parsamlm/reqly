using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Reqly.Https;

/// <summary>
/// Sets up HTTPS decryption: Reqly creates its certificate, and Windows trusts it once you
/// confirm, as the Mac app's setup sheet does.
/// </summary>
public sealed class HttpsSetupDialog
{
    private readonly HttpsModel https;
    private readonly ContentDialog dialog;
    private readonly StackPanel progress;
    private readonly TextBlock progressText;
    private readonly TextBlock failure;

    public HttpsSetupDialog(HttpsModel https, XamlRoot root)
    {
        this.https = https;
        progressText = new TextBlock { Foreground = Brush("TextFillColorSecondaryBrush"), TextWrapping = TextWrapping.Wrap };
        progress = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        progress.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        progress.Children.Add(progressText);
        failure = new TextBlock { Foreground = Brush("SystemFillColorCriticalBrush"), TextWrapping = TextWrapping.Wrap };
        var content = new StackPanel { Spacing = 12, MaxWidth = 440 };
        content.Children.Add(new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Text = "To show what's inside HTTPS requests, Reqly creates its own certificate on your PC, and Windows trusts it for your user account. Reqly decrypts only the hosts you choose. Everything else passes through untouched.",
        });
        content.Children.Add(new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Foreground = Brush("TextFillColorSecondaryBrush"),
            Text = "Windows asks you to confirm before it trusts the certificate. You can remove it at any time in Settings, under HTTPS.",
        });
        content.Children.Add(progress);
        content.Children.Add(failure);
        dialog = new ContentDialog
        {
            XamlRoot = root,
            Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"],
            Title = "Set up HTTPS",
            Content = content,
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        dialog.PrimaryButtonClick += OnPrimaryButtonClicked;
    }

    /// <summary>The dialog itself, for the self-check's picture of it.</summary>
    public UIElement View => dialog;

    /// <summary>Shows setup, and returns once it closes: set up, or cancelled.</summary>
    public async Task ShowAsync()
    {
        https.Changed += Update;
        Update();
        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
            https.Changed -= Update;
            if (!https.IsTrusted)
            {
                https.CancelSetup();
            }
        }
    }

    public void Hide() => dialog.Hide();

    private void OnPrimaryButtonClicked(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        // The dialog stays open while Windows asks you, and closes once the certificate is trusted.
        args.Cancel = true;
        _ = SetUpAsync();
    }

    private async Task SetUpAsync()
    {
        await https.SetUpAsync();
        if (https.IsTrusted)
        {
            dialog.Hide();
        }
    }

    private void Update()
    {
        dialog.PrimaryButtonText = https.HasCertificate ? "Trust certificate" : "Create and trust certificate";
        dialog.IsPrimaryButtonEnabled = !https.IsWorking;
        progress.Visibility = https.IsWorking ? Visibility.Visible : Visibility.Collapsed;
        progressText.Text = https.IsWorking ? https.Message ?? "" : "";
        var failed = https.Status == HttpsModel.Phase.Failed;
        failure.Visibility = failed ? Visibility.Visible : Visibility.Collapsed;
        failure.Text = failed ? https.Message ?? "" : "";
    }

    private static Brush Brush(string name) => (Brush)Application.Current.Resources[name];
}
