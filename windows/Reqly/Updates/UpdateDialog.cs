using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Reqly.Updates;

/// <summary>What Check for updates shows, over the window it was chosen in.</summary>
public static class UpdateDialog
{
    /// <summary>The dialog while it shows, for the self-check.</summary>
    public static ContentDialog? Showing { get; private set; }

    /// <summary>
    /// Checks for a newer Reqly and says what it found. With an update ready, it offers to restart
    /// Reqly to install it.
    /// </summary>
    public static async Task ShowAsync(XamlRoot root)
    {
        var updates = App.Current.Updates;
        var text = new TextBlock { Text = "Checking for updates…", TextWrapping = TextWrapping.Wrap };
        var dialog = new ContentDialog
        {
            Title = "Updates",
            Content = text,
            CloseButtonText = "OK",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = root,
            Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"],
        };
        try
        {
            // It shows at once, and says what the check found once it's done.
            var answered = dialog.ShowAsync().AsTask();
            Showing = dialog;
            text.Text = await updates.CheckAsync();
            if (updates.ReadyVersion is not null)
            {
                // Quitting lets go of the traffic captured so far, as it does on the Mac.
                text.Text += " To install it now, Reqly quits and opens again. The traffic so far goes with it, so save it first if you want to keep it.";
                dialog.PrimaryButtonText = "Restart to update";
                dialog.CloseButtonText = "Later";
                dialog.DefaultButton = ContentDialogButton.Primary;
            }
            if (await answered == ContentDialogResult.Primary)
            {
                App.Current.RestartToUpdate();
            }
        }
        catch (Exception error)
        {
            // Another dialog was showing.
            AppLog.Write($"the updates dialog didn't show: {error.Message}");
        }
        finally
        {
            Showing = null;
        }
    }
}
