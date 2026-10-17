using System.Text.Json.Nodes;
using Microsoft.UI.Xaml.Controls;
using Reqly.Core;
using Reqly.Traffic;

namespace Reqly;

/// <summary>The selected request's details, and keeping the selection as rows come and go.</summary>
public sealed partial class MainWindow
{
    /// <summary>
    /// The selected exchange. It stays selected while the sidebar, a filter or the search hides
    /// its row, and its details stay, as on the Mac; it's let go only when it leaves the session.
    /// </summary>
    private ulong? selectedExchange;
    /// <summary>What the details showed of the selected exchange last, to tell when it moved on.</summary>
    private (string State, int? Status, long Received)? shownState;
    /// <summary>Set while the window selects a row itself, so the list's own change is ignored.</summary>
    private bool isRestoringSelection;
    /// <summary>
    /// An exchange to select once its row shows, such as a request just sent, and since when. The
    /// session records it a moment later, so until then it's waited for rather than let go.
    /// </summary>
    private (ulong Id, DateTime Since)? awaitedRow;

    private bool IsAwaited(ulong id) =>
        awaitedRow is { } awaited && awaited.Id == id && DateTime.UtcNow - awaited.Since < TimeSpan.FromSeconds(10);

    private RequestRow? SelectedRow => selectedExchange is ulong id ? list?.Row(id) : null;

    /// <summary>Requests and responses held at breakpoints, by exchange.</summary>
    private readonly Dictionary<ulong, WirePaused> paused = [];

    /// <summary>The paused editor in place of the details, while the selected exchange waits at a breakpoint.</summary>
    private void ShowPausedIfSelected()
    {
        if (selectedExchange is ulong id && paused.TryGetValue(id, out var held))
        {
            if (PausedArea.Content is Inspector.PausedEditor { } editor && editor.Exchange == id)
            {
                return;
            }
            var row = list?.Row(id);
            var subtitle = string.Join(" · ", new[] { row?.DisplayHost, row?.App }.Where(part => !string.IsNullOrEmpty(part)));
            PausedArea.Content = new Inspector.PausedEditor(held, paused.Count - 1, subtitle, edit => DecideAsync(id, edit));
            PausedArea.Visibility = Microsoft.UI.Xaml.Visibility.Visible;
            Inspector.Visibility = Microsoft.UI.Xaml.Visibility.Collapsed;
        }
        else if (PausedArea.Visibility == Microsoft.UI.Xaml.Visibility.Visible)
        {
            PausedArea.Content = null;
            PausedArea.Visibility = Microsoft.UI.Xaml.Visibility.Collapsed;
            Inspector.Visibility = Microsoft.UI.Xaml.Visibility.Visible;
            if (selectedExchange is ulong shown)
            {
                _ = Inspector.ShowAsync(shown);
            }
        }
    }

    /// <summary>Lets a held exchange go on, edited, or with no edit, cancels it; says what to fix if it can't go on.</summary>
    private async Task<string?> DecideAsync(ulong id, JsonObject? edit)
    {
        if (session is null)
        {
            return null;
        }
        var request = new JsonObject { ["call"] = "decide", ["id"] = id };
        if (edit is not null)
        {
            request["edit"] = edit;
        }
        try
        {
            await session.CallAsync(request);
            return null;
        }
        catch (CoreProblem problem) when (problem.Code == "badRequest")
        {
            return problem.Message;
        }
        catch (CoreProblem problem)
        {
            Log($"couldn't decide: {problem.Message}");
            return null;
        }
    }

    private async void OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        foreach (var removed in e.RemovedItems.OfType<RequestRow>())
        {
            removed.IsSelected = false;
        }
        foreach (var added in e.AddedItems.OfType<RequestRow>())
        {
            added.IsSelected = true;
        }
        if (isRestoringSelection)
        {
            return;
        }
        if (List.SelectedItem is RequestRow row)
        {
            selectedExchange = row.ID;
            shownState = StateOf(row);
            ShowPausedIfSelected();
            UpdateMenus();
            await Inspector.ShowAsync(row.ID);
        }
        else if (e.RemovedItems.Count > 0 && list?.Row(((RequestRow)e.RemovedItems[0]).ID) is not null)
        {
            // You cleared the selection; a row that went away doesn't count.
            selectedExchange = null;
            Inspector.ShowNothing();
            UpdateMenus();
        }
    }

    private static (string, int?, long)? StateOf(RequestRow row) =>
        row.Contents is { } contents ? (contents.State, contents.Status, contents.BytesReceived) : null;

    /// <summary>Selects the selected exchange's row again after the rows changed, if it shows.</summary>
    private void KeepSelection()
    {
        if (selectedExchange is not ulong id || list is null)
        {
            return;
        }
        if (list.Row(id) is { } row)
        {
            if (awaitedRow?.Id == id)
            {
                awaitedRow = null;
            }
            if (!ReferenceEquals(List.SelectedItem, row))
            {
                isRestoringSelection = true;
                List.SelectedItem = row;
                isRestoringSelection = false;
            }
            if (StateOf(row) is { } state && state != shownState)
            {
                // A live exchange moves on: its details follow, on the same tab.
                shownState = state;
                _ = Inspector.ShowAsync(id);
            }
        }
        else if (!IsAwaited(id))
        {
            _ = ForgetIfGoneAsync(id);
        }
    }

    /// <summary>Lets go of the selection once its exchange is no longer in the session.</summary>
    private async Task ForgetIfGoneAsync(ulong id)
    {
        if (session is null)
        {
            return;
        }
        try
        {
            await session.CallAsync(new JsonObject { ["call"] = "details", ["id"] = id });
        }
        catch (CoreProblem problem) when (problem.Code == "notFound")
        {
            if (selectedExchange == id && !IsAwaited(id))
            {
                selectedExchange = null;
                Inspector.ShowNothing();
            }
        }
    }
}
