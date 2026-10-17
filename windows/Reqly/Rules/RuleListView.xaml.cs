using System.Collections.ObjectModel;
using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Reqly.Core;
using Windows.System;

namespace Reqly.Rules;

/// <summary>
/// A kind of rule in the Rules window: its switch, then its rules in the order they act. Drag a
/// rule to move it; double-click it, or press Enter, to edit it.
/// </summary>
public sealed partial class RuleListView : UserControl
{
    private readonly RulesModel rules;
    private readonly RuleKinds.Kind kind;
    private readonly Func<WireRuleDraft, Task> edit;
    private readonly ObservableCollection<RuleItem> items = [];
    private bool isShowing;

    public RuleListView(RulesModel rules, string kind, Func<WireRuleDraft, Task> edit)
    {
        this.rules = rules;
        this.kind = RuleKinds.Of(kind);
        this.edit = edit;
        InitializeComponent();
        RuleList.ItemsSource = items;
        KindTitle.Text = this.kind.Title;
        KindExplanation.Text = this.kind.Explanation;
        AutomationProperties.SetName(KindSwitch, this.kind.Title);
        Footer.Text = $"Rules match a host, a path and a method. Use * to match anything. {this.kind.OrderNote} You can also add a rule by right-clicking a request.";
        Loaded += (_, _) =>
        {
            rules.Changed += Show;
            Show();
        };
        Unloaded += (_, _) => rules.Changed -= Show;
    }

    private RuleItem? Selected => RuleList.SelectedItem as RuleItem;

    /// <summary>What the list shows, for the self-check.</summary>
    public string Describe() => string.Join(", ", items.Select(item => $"{item.Name} [{item.What}]{(item.IsOn ? "" : " off")}"));

    private void Show()
    {
        isShowing = true;
        KindSwitch.IsOn = rules.IsOn(kind.Id);
        var rows = rules.Of(kind.Id);
        if (rows.Select(row => row.Id).SequenceEqual(items.Select(item => item.Id)))
        {
            // The same rules in the same order: each changes in place, so a switch keeps its focus.
            for (var index = 0; index < rows.Length; index++)
            {
                items[index].Update(rows[index]);
            }
        }
        else
        {
            var selected = Selected?.Id;
            items.Clear();
            foreach (var row in rows)
            {
                var id = row.Id;
                var item = new RuleItem(id, isOn => _ = rules.SetRuleOnAsync(id, isOn));
                item.Update(row);
                items.Add(item);
            }
            RuleList.SelectedItem = items.FirstOrDefault(item => item.Id == selected);
        }
        NoRules.Visibility = items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        RuleList.Visibility = items.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        isShowing = false;
        ShowButtons();
    }

    private void ShowButtons()
    {
        RemoveButton.IsEnabled = Selected is not null;
        EditButton.IsEnabled = Selected is not null;
    }

    private void OnKindToggled(object sender, RoutedEventArgs e)
    {
        if (!isShowing && KindSwitch.IsOn != rules.IsOn(kind.Id))
        {
            _ = rules.SetOnAsync(kind.Id, KindSwitch.IsOn);
        }
    }

    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e) => ShowButtons();

    private async void OnAddClicked(object sender, RoutedEventArgs e) => await AddAsync();

    public async Task AddAsync()
    {
        try
        {
            await edit(await rules.NewDraftAsync(kind.Id));
        }
        catch (CoreProblem problem)
        {
            AppLog.Write($"couldn't start a rule: {problem.Message}");
        }
    }

    private async void OnEditClicked(object sender, RoutedEventArgs e) => await EditAsync(Selected);

    private async Task EditAsync(RuleItem? item)
    {
        if (item is null)
        {
            return;
        }
        try
        {
            await edit(await rules.DraftAsync(item.Id));
        }
        catch (CoreProblem problem)
        {
            AppLog.Write($"couldn't edit the rule: {problem.Message}");
        }
    }

    private void OnRemoveClicked(object sender, RoutedEventArgs e) => Remove(Selected);

    private void Remove(RuleItem? item)
    {
        if (item is not null)
        {
            _ = rules.RemoveAsync(item.Id);
        }
    }

    private async void OnListDoubleTapped(object sender, DoubleTappedRoutedEventArgs e) =>
        await EditAsync((e.OriginalSource as FrameworkElement)?.DataContext as RuleItem);

    private async void OnListKeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Delete:
                e.Handled = true;
                Remove(Selected);
                break;
            case VirtualKey.Enter:
                e.Handled = true;
                await EditAsync(Selected);
                break;
        }
    }

    /// <summary>A rule dragged to another place acts in that order from now on.</summary>
    private void OnDragCompleted(ListViewBase sender, DragItemsCompletedEventArgs args)
    {
        if (args.DropResult == Windows.ApplicationModel.DataTransfer.DataPackageOperation.None || args.Items.FirstOrDefault() is not RuleItem item)
        {
            return;
        }
        _ = rules.MoveAsync(item.Id, items.IndexOf(item));
    }

    private void OnContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        var item = (args.OriginalSource as FrameworkElement)?.DataContext as RuleItem
            ?? (args.OriginalSource as ListViewItem)?.Content as RuleItem;
        if (item is null)
        {
            return;
        }
        args.Handled = true;
        RuleList.SelectedItem = item;
        var place = items.IndexOf(item);
        var menu = new MenuFlyout();
        menu.Items.Add(MenuItem("Edit…", () => _ = EditAsync(item)));
        menu.Items.Add(MenuItem("Duplicate", () => _ = rules.DuplicateAsync(item.Id)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(MenuItem("Move up", () => _ = rules.MoveAsync(item.Id, place - 1), place > 0));
        menu.Items.Add(MenuItem("Move down", () => _ = rules.MoveAsync(item.Id, place + 1), place < items.Count - 1));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(MenuItem("Delete", () => Remove(item)));
        if (args.TryGetPosition(RuleList, out var point))
        {
            menu.ShowAt(RuleList, point);
        }
        else
        {
            menu.ShowAt(RuleList, new Microsoft.UI.Xaml.Controls.Primitives.FlyoutShowOptions());
        }
    }

    private static MenuFlyoutItem MenuItem(string text, Action action, bool isEnabled = true)
    {
        var item = new MenuFlyoutItem { Text = text, IsEnabled = isEnabled };
        item.Click += (_, _) => action();
        return item;
    }
}

/// <summary>A rule in the list: its switch, its name and what it matches, and a word on what it does.</summary>
public sealed partial class RuleItem(Guid id, Action<bool> setOn) : INotifyPropertyChanged
{
    public Guid Id { get; } = id;
    public string Name { get; private set; } = "";
    /// <summary>Such as "GET · api.weatherly.dev/v2/forecast*".</summary>
    public string Match { get; private set; } = "";
    /// <summary>What the rule does, in a word or two, such as "Response" or "403".</summary>
    public string What { get; private set; } = "";
    public bool IsOn { get; private set; }
    /// <summary>A rule that's off shows dimmed.</summary>
    public double Opacity => IsOn ? 1 : 0.6;

    public event PropertyChangedEventHandler? PropertyChanged;

    public void Update(WireRuleRow row)
    {
        Set(row.Name, Name, value => Name = value, nameof(Name));
        Set(row.Match, Match, value => Match = value, nameof(Match));
        Set(row.Tag, What, value => What = value, nameof(What));
        if (row.IsOn != IsOn)
        {
            IsOn = row.IsOn;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsOn)));
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Opacity)));
        }
    }

    private void Set(string value, string old, Action<string> set, string property)
    {
        if (value != old)
        {
            set(value);
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));
        }
    }

    public void OnToggled(object sender, RoutedEventArgs e)
    {
        if (sender is ToggleSwitch toggle && toggle.IsOn != IsOn)
        {
            setOn(toggle.IsOn);
        }
    }
}
