using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Reqly.Core;
using Reqly.Inspector;
using Reqly.Traffic;
using Windows.Storage.Pickers;

namespace Reqly;

/// <summary>Opening, saving and exporting traffic, and the menu bar's other commands, as the Mac's File and Request menus have them.</summary>
public sealed partial class MainWindow
{
    /// <summary>The menus' words and what they can do, for the selection and the session as they are.</summary>
    private void UpdateMenus()
    {
        var total = list?.Total ?? 0;
        var row = SelectedRow;
        SaveItem.IsEnabled = total > 0;
        ExportItem.IsEnabled = total > 0;
        CaptureItem.Text = capture == Capture.Capturing ? "Stop capturing" : "Start capturing";
        CaptureItem.IsEnabled = capture is Capture.Stopped or Capture.Capturing && session is not null;
        ClearItem.IsEnabled = total > (sidebar?.Pinned ?? 0);
        CopyUrlItem.IsEnabled = row?.Contents is not null;
        CopyCurlItem.IsEnabled = row is { IsReadable: true };
        CopyBodyItem.IsEnabled = row is { IsReadable: true, Contents.Status: not null };
        PinItem.IsEnabled = row?.Contents is not null;
        PinItem.Text = row is { IsPinned: true } ? "Unpin request" : "Pin request";
        UnpinAllItem.IsEnabled = (sidebar?.Pinned ?? 0) > 0;
        CommentItem.IsEnabled = row?.Contents is not null;
        CommentItem.Text = row?.Comment is null ? "Add comment…" : "Edit comment…";
        ResendItem.IsEnabled = row is { IsReadable: true };
        EditResendItem.IsEnabled = row is { IsReadable: true };
        ShowAddRuleMenu(AddRuleItem, row);
        ContinueAllItem.IsEnabled = paused.Count > 0;
    }

    // MARK: Sending

    private void OnNewRequestClicked(object sender, RoutedEventArgs e) => App.Current.Main?.ShowComposer(null);

    private void OnResendClicked(object sender, RoutedEventArgs e)
    {
        if (SelectedRow is { IsReadable: true } row)
        {
            _ = ResendAsync(row);
        }
    }

    private void OnEditResendClicked(object sender, RoutedEventArgs e)
    {
        if (SelectedRow is { IsReadable: true } row)
        {
            _ = EditAndResendAsync(row);
        }
    }

    /// <summary>The composer windows open, which close with this window.</summary>
    private readonly List<Reqly.Compose.ComposerWindow> composers = [];

    /// <summary>A composer window, blank or filled in, sending from the session being captured.</summary>
    public Reqly.Compose.ComposerWindow? ShowComposer(WireOutgoing? draft)
    {
        if (session is null || file is not null)
        {
            return null;
        }
        var composer = new Reqly.Compose.ComposerWindow(session, draft, CopyText);
        composers.Add(composer);
        composer.Closed += (_, _) => composers.Remove(composer);
        composer.Activate();
        return composer;
    }

    /// <summary>
    /// Sends a request again, as it was, from the session being captured, and selects it there. A
    /// request in a saved file is sent from there too, and its window comes forward.
    /// </summary>
    private async Task ResendAsync(RequestRow row)
    {
        if (session is null)
        {
            return;
        }
        try
        {
            if (file is null)
            {
                var result = await session.CallAsync(new JsonObject { ["call"] = "resend", ["id"] = row.ID });
                SelectWhenItShows(result.GetProperty("id").GetUInt64());
            }
            else if (await DraftAsync(row) is { } draft && App.Current.Main is { } main)
            {
                await main.SendAsync(draft);
                main.BringForward();
            }
        }
        catch (CoreProblem problem)
        {
            Log($"couldn't resend: {problem.Message}");
        }
    }

    private async Task EditAndResendAsync(RequestRow row)
    {
        if (await DraftAsync(row) is { } draft)
        {
            App.Current.Main?.ShowComposer(draft);
        }
    }

    private async Task<WireOutgoing?> DraftAsync(RequestRow row)
    {
        if (session is null)
        {
            return null;
        }
        try
        {
            return Wire.Read<WireOutgoing>(await session.CallAsync(new JsonObject { ["call"] = "draft", ["id"] = row.ID }));
        }
        catch (CoreProblem problem)
        {
            Log($"couldn't fill in a draft: {problem.Message}");
            return null;
        }
    }

    /// <summary>Sends a request written elsewhere, as a saved file's Resend does, and selects it.</summary>
    public async Task SendAsync(WireOutgoing draft)
    {
        if (session is null)
        {
            return;
        }
        var request = new JsonObject { ["call"] = "send", ["request"] = System.Text.Json.JsonSerializer.SerializeToNode(draft, Wire.Options) };
        var result = await session.CallAsync(request);
        SelectWhenItShows(result.GetProperty("id").GetUInt64());
    }

    /// <summary>Selects an exchange as soon as its row shows, as after Resend.</summary>
    private void SelectWhenItShows(ulong id)
    {
        selectedExchange = id;
        shownState = null;
        awaitedRow = (id, DateTime.UtcNow);
        KeepSelection();
    }

    private void OnCloseClicked(object sender, RoutedEventArgs e) => CloseOrHide();

    private void OnQuitClicked(object sender, RoutedEventArgs e) => App.Current.Quit();

    private void OnCopyUrlClicked(object sender, RoutedEventArgs e) => _ = CopyUrlAsync(SelectedRow);

    private void OnCopyCurlClicked(object sender, RoutedEventArgs e) => _ = CopyCurlAsync(SelectedRow);

    private void OnCopyBodyClicked(object sender, RoutedEventArgs e)
    {
        if (SelectedRow is { } row)
        {
            _ = CopyResponseBodyAsync(row);
        }
    }

    private void OnPinClicked(object sender, RoutedEventArgs e)
    {
        if (SelectedRow is { } row)
        {
            _ = AnnotateAsync(row, new JsonObject { ["isPinned"] = !row.IsPinned });
        }
    }

    private async void OnUnpinAllClicked(object sender, RoutedEventArgs e)
    {
        if (session is not null)
        {
            await session.CallAsync(new JsonObject { ["call"] = "unpinAll" });
        }
    }

    private void OnCommentClicked(object sender, RoutedEventArgs e)
    {
        if (SelectedRow is { } row)
        {
            _ = EditCommentAsync(row);
        }
    }

    private void OnTabMenuClicked(object sender, RoutedEventArgs e)
    {
        if (sender is MenuFlyoutItem { Tag: string tab })
        {
            Inspector.ShowTab(tab);
        }
    }

    private void OnSidebarMenuClicked(object sender, RoutedEventArgs e) => Navigation.IsPaneOpen = !Navigation.IsPaneOpen;

    private void OnHelpClicked(object sender, RoutedEventArgs e) => OpenHelp();

    /// <summary>Reqly's help, on reqly.net, in your browser.</summary>
    private static void OpenHelp() => _ = Windows.System.Launcher.LaunchUriAsync(new Uri("https://reqly.net/docs/"));

    private void OnAboutClicked(object sender, RoutedEventArgs e) => App.Current.ShowAbout(this);

    /// <summary>Opens a new issue on GitHub, with Reqly's and Windows' versions filled in, for a problem that isn't a crash.</summary>
    private void OnReportProblemClicked(object sender, RoutedEventArgs e) => CrashReports.CrashReporter.Open(CrashReports.CrashReporter.ProblemUrl);

    private async void OnCheckForUpdatesClicked(object sender, RoutedEventArgs e) => await ShowUpdatesAsync();

    /// <summary>Checks for a newer Reqly, as Help › Check for updates does, and says what it found, over this window.</summary>
    public Task ShowUpdatesAsync() => Updates.UpdateDialog.ShowAsync(Root.XamlRoot);

    // MARK: Files

    private void OnOpenClicked(object sender, RoutedEventArgs e) => _ = PickFileToOpenAsync();

    /// <summary>Asks for a saved session or a HAR file, and opens it in a window of its own.</summary>
    private async Task PickFileToOpenAsync()
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".reqly");
        picker.FileTypeFilter.Add(".har");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFileAsync() is { } chosen)
        {
            App.Current.OpenFile(chosen.Path);
        }
    }

    private void OnSaveClicked(object sender, RoutedEventArgs e) => _ = SaveSessionAsync();

    /// <summary>
    /// Asks where to save the session, then saves it as a file that Reqly opens on a Mac or a PC.
    /// Secrets stay in it unless you choose to hide them.
    /// </summary>
    private async Task SaveSessionAsync()
    {
        if (session is null || (list?.Total ?? 0) == 0 || Root.XamlRoot is null)
        {
            return;
        }
        var hides = new CheckBox { Content = "Hide authorization headers and cookies", IsChecked = settings.HidesSecretsInSessions };
        var dialog = Dialog("Save session", hides, "Save…");
        if (!await ShowDialogAsync(dialog))
        {
            return;
        }
        settings.HidesSecretsInSessions = hides.IsChecked == true;
        settings.Save();
        var picker = new FileSavePicker
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
            SuggestedFileName = file is not null ? Path.GetFileNameWithoutExtension(file) : $"Reqly Session {FileStamp(DateTime.Now)}",
        };
        picker.FileTypeChoices.Add("Reqly session", [".reqly"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSaveFileAsync() is { } chosen)
        {
            await SaveSessionAsync(chosen.Path, settings.HidesSecretsInSessions);
        }
    }

    /// <summary>Saves the session to a file, and says so in the status bar.</summary>
    private async Task SaveSessionAsync(string path, bool hidesSecrets)
    {
        if (session is null)
        {
            return;
        }
        try
        {
            await session.CallAsync(new JsonObject { ["call"] = "saveSession", ["path"] = path, ["hidesSecrets"] = hidesSecrets });
            Log($"saved the session to {path}");
        }
        catch (CoreProblem problem)
        {
            await TellAsync("Reqly couldn't save the session.", problem.Message);
        }
    }

    private void OnExportClicked(object sender, RoutedEventArgs e) => _ = ExportHarAsync();

    /// <summary>Exports the selected request, or the whole list as it shows, to a HAR file, as the Mac's Export as HAR sheet does.</summary>
    private async Task ExportHarAsync()
    {
        if (session is null || list is null || list.Total == 0 || Root.XamlRoot is null)
        {
            return;
        }
        var listed = list.Rows.Count(row => row.IsReadable);
        var selected = SelectedRow is { IsReadable: true } row ? row : null;
        var content = new StackPanel { Spacing = 12, MaxWidth = 460 };
        content.Children.Add(Blocks.Note("Save requests as a HAR file that you can open in browsers and other tools."));
        var scope = new RadioButtons();
        if (selected is not null)
        {
            scope.Items.Add("Selected request (1)");
        }
        scope.Items.Add($"All requests in this list ({listed:N0})");
        scope.SelectedIndex = 0;
        content.Children.Add(scope);
        if (list.Rows.Count > listed)
        {
            content.Children.Add(Blocks.Note("Encrypted connections are left out, since their requests can't be read."));
        }
        var bodies = new CheckBox { Content = "Include response bodies", IsChecked = settings.HarIncludesResponseBodies };
        var hides = new CheckBox { Content = "Hide authorization headers and cookies", IsChecked = settings.HidesSecretsInHar };
        content.Children.Add(bodies);
        content.Children.Add(hides);
        var warning = new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Informational };
        void ShowWarning() => warning.Message = hides.IsChecked == true
            ? "Authorization headers and cookies are hidden. Bodies can still hold personal data, so share HAR files with care."
            : "HAR files contain everything in the requests, including cookies and tokens. Share them with care.";
        hides.Click += (_, _) => ShowWarning();
        ShowWarning();
        content.Children.Add(warning);
        var dialog = Dialog("Export as HAR", content, "Export…");
        if (!await ShowDialogAsync(dialog))
        {
            return;
        }
        settings.HarIncludesResponseBodies = bodies.IsChecked == true;
        settings.HidesSecretsInHar = hides.IsChecked == true;
        settings.Save();
        var onlySelected = selected is not null && scope.SelectedIndex == 0;
        var picker = new FileSavePicker
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
            SuggestedFileName = $"{(onlySelected ? selected!.Host : "Reqly")} {FileStamp(DateTime.Now)}",
        };
        picker.FileTypeChoices.Add("HTTP Archive", [".har"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSaveFileAsync() is { } chosen)
        {
            await ExportHarAsync(chosen.Path, onlySelected ? [selected!.ID] : null, settings.HarIncludesResponseBodies, settings.HidesSecretsInHar);
        }
    }

    /// <summary>Exports to a HAR file: some exchanges, or with none given, the list as it shows.</summary>
    private async Task<int> ExportHarAsync(string path, ulong[]? ids, bool includesBodies, bool hidesSecrets)
    {
        if (session is null)
        {
            return 0;
        }
        var request = new JsonObject
        {
            ["call"] = "exportHAR",
            ["path"] = path,
            ["includesResponseBodies"] = includesBodies,
            ["hidesSecrets"] = hidesSecrets,
            ["version"] = Help.AppInfo.Version,
        };
        if (ids is not null)
        {
            request["ids"] = new JsonArray(ids.Select(id => (JsonNode)JsonValue.Create(id)).ToArray());
        }
        var before = StatusText.Text;
        StatusText.Text = "Exporting…";
        try
        {
            var result = await session.CallAsync(request);
            var exported = result.GetProperty("exported").GetInt32();
            Log($"exported {exported} to {path}");
            return exported;
        }
        catch (CoreProblem problem)
        {
            await TellAsync("Reqly couldn't export.", problem.Message);
            return 0;
        }
        finally
        {
            StatusText.Text = before;
            ShowStatus();
        }
    }

    /// <summary>The date and time for a file's name, as Windows names screenshots: 2026-10-03 at 10.15.</summary>
    private static string FileStamp(DateTime date) => $"{date:yyyy-MM-dd} at {date:HH.mm}";

    private ContentDialog Dialog(string title, object content, string primary) => new()
    {
        XamlRoot = Root.XamlRoot,
        Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"],
        Title = title,
        Content = content,
        PrimaryButtonText = primary,
        CloseButtonText = "Cancel",
        DefaultButton = ContentDialogButton.Primary,
    };

    /// <summary>Shows a dialog and says whether you went ahead. Only one dialog shows at a time.</summary>
    private async Task<bool> ShowDialogAsync(ContentDialog dialog)
    {
        try
        {
            return await dialog.ShowAsync() == ContentDialogResult.Primary;
        }
        catch (Exception error)
        {
            Log($"a dialog didn't show: {error.Message}");
            return false;
        }
    }

    /// <summary>Says what went wrong, in a dialog with an OK button.</summary>
    private async Task TellAsync(string title, string message)
    {
        Log($"{title} {message}");
        if (Root.XamlRoot is null || options.SmokeReport is not null)
        {
            return;
        }
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"],
            Title = title,
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            CloseButtonText = "OK",
        };
        await ShowDialogAsync(dialog);
    }
}
