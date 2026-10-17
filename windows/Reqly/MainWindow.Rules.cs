using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Reqly.Core;
using Reqly.Rules;
using Reqly.Traffic;

namespace Reqly;

/// <summary>The rules, as on the Mac: the Rules window, the switches in the menu and the toolbar, and Add rule on a request.</summary>
public sealed partial class MainWindow
{
    private RulesModel? rules;
    private RulesWindow? rulesWindow;

    /// <summary>The rules for the traffic being captured, once they're open.</summary>
    public RulesModel? Rules => rules;

    private async Task OpenRulesAsync(CoreSession session)
    {
        rules = new RulesModel(session);
        rules.Changed += ShowRuleSwitches;
        await rules.OpenAsync(options.RulesFile);
        var problem = rules.Rules.Problem is { } text ? $" · {text}" : "";
        Log($"rules: {rules.Rules.Rules.Length}, on: {string.Join(", ", rules.Rules.KindsOn)}{problem}");
    }

    /// <summary>Opens the Rules window, on a kind of rule when one is meant. A file's window opens the main window's.</summary>
    public RulesWindow? ShowRules(string? kind = null)
    {
        if (file is not null)
        {
            return App.Current.Main?.ShowRules(kind);
        }
        if (rules is null)
        {
            return null;
        }
        if (rulesWindow is null)
        {
            rulesWindow = new RulesWindow(rules);
            rulesWindow.Closed += (_, _) => rulesWindow = null;
        }
        if (kind is not null)
        {
            rulesWindow.Show(kind);
        }
        rulesWindow.Activate();
        return rulesWindow;
    }

    /// <summary>Opens the Rules window's editor on a rule you're adding.</summary>
    public void EditRule(WireRuleDraft draft)
    {
        if (ShowRules(draft.Kind) is { } window)
        {
            _ = window.EditAsync(draft);
        }
    }

    /// <summary>
    /// Turns a kind of rule on or off, as the menu, the toolbar and the notification area's panel
    /// do. Turning on a kind with no rules yet opens the Rules window on it, so you can add one.
    /// </summary>
    public async Task SetRuleKindOnAsync(string kind, bool isOn)
    {
        if (rules is null)
        {
            return;
        }
        await rules.SetOnAsync(kind, isOn);
        // Changing nothing leaves the switches as they were, so they're shown again either way.
        ShowRuleSwitches();
        if (isOn && kind != "slowNetwork" && rules.Of(kind).Length == 0)
        {
            ShowRules(kind);
        }
    }

    private void ToggleRuleKind(string kind)
    {
        if (rules is not null)
        {
            _ = SetRuleKindOnAsync(kind, !rules.IsOn(kind));
        }
    }

    private void OnRuleKindItemClicked(object sender, RoutedEventArgs e)
    {
        if (sender is ToggleMenuFlyoutItem { Tag: string kind } item)
        {
            _ = SetRuleKindOnAsync(kind, item.IsChecked);
        }
    }

    private void OnRuleKindButtonClicked(object sender, RoutedEventArgs e)
    {
        if (sender is ToggleButton { Tag: string kind } button)
        {
            _ = SetRuleKindOnAsync(kind, button.IsChecked == true);
        }
    }

    private void OnShowRulesClicked(object sender, RoutedEventArgs e) => ShowRules();

    private void OnContinueAllClicked(object sender, RoutedEventArgs e) => _ = ContinueAllPausedAsync();

    /// <summary>Lets every request and response held at a breakpoint go on as it came.</summary>
    private async Task ContinueAllPausedAsync()
    {
        if (session is null || paused.Count == 0)
        {
            return;
        }
        try
        {
            await session.CallAsync(new JsonObject { ["call"] = "continueAllPaused" });
        }
        catch (CoreProblem problem)
        {
            Log($"couldn't continue the paused requests: {problem.Message}");
        }
    }

    /// <summary>The switches in the Rules menu and on the toolbar, as the rules are.</summary>
    private void ShowRuleSwitches()
    {
        if (rules is null)
        {
            return;
        }
        foreach (var item in RulesMenu.Items.OfType<ToggleMenuFlyoutItem>())
        {
            if (item.Tag is string kind)
            {
                item.IsChecked = rules.IsOn(kind);
            }
        }
        var breakpoints = rules.IsOn("breakpoint");
        BreakpointsButton.IsChecked = breakpoints;
        ToolTipService.SetToolTip(BreakpointsButton, breakpoints ? "Breakpoints are on (Ctrl+Shift+B)" : "Turn on breakpoints (Ctrl+Shift+B)");
        var slow = rules.IsOn("slowNetwork");
        SlowNetworkButton.IsChecked = slow;
        ToolTipService.SetToolTip(
            SlowNetworkButton, slow ? $"Slow Network is on: {rules.Rules.Network.Profile.Name} (Ctrl+Shift+T)" : "Turn on Slow Network (Ctrl+Shift+T)");
    }

    /// <summary>
    /// Add rule, with each kind, for a request: the one you right-clicked, or with none, the selected
    /// one when you choose.
    /// </summary>
    private MenuFlyoutSubItem AddRuleMenu(MenuFlyoutSubItem? menu = null, RequestRow? row = null)
    {
        menu ??= new MenuFlyoutSubItem { Text = "Add rule" };
        foreach (var kind in RuleKinds.Rules)
        {
            var id = kind.Id;
            var item = new MenuFlyoutItem { Text = kind.MenuTitle, Tag = id };
            item.Click += (_, _) =>
            {
                if ((row ?? SelectedRow) is { Contents: not null } chosen)
                {
                    _ = AddRuleAsync(chosen, id);
                }
            };
            menu.Items.Add(item);
        }
        ShowAddRuleMenu(menu, row);
        return menu;
    }

    /// <summary>Which kinds a request can have a rule of. An encrypted connection can only be blocked.</summary>
    private void ShowAddRuleMenu(MenuFlyoutSubItem menu, RequestRow? row)
    {
        foreach (var item in menu.Items.OfType<MenuFlyoutItem>())
        {
            item.IsEnabled = row?.Contents is not null && (row.IsReadable || item.Tag as string == "block");
        }
        menu.IsEnabled = row?.Contents is not null && (file is not null || rules is not null);
    }

    /// <summary>
    /// Starts a rule from a request: its host, its path and its method. A saved session's request
    /// starts one for the traffic being captured.
    /// </summary>
    private async Task AddRuleAsync(RequestRow row, string kind)
    {
        if (session is null)
        {
            return;
        }
        WireRuleDraft draft;
        try
        {
            draft = await RulesModel.NewDraftAsync(session, kind, row.ID);
        }
        catch (CoreProblem problem)
        {
            Log($"couldn't start a rule: {problem.Message}");
            return;
        }
        if (file is not null)
        {
            // The request isn't in the traffic being captured, so its response can't be saved from there.
            draft.Exchange = null;
            App.Current.Main?.EditRule(draft);
            return;
        }
        EditRule(draft);
    }
}
