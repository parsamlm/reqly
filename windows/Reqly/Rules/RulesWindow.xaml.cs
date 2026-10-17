using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Reqly.Core;
using Windows.Graphics;

namespace Reqly.Rules;

/// <summary>
/// The Rules window, as the Mac's: a section for each kind of rule, with its switch and its rules
/// in the order they act, and Slow Network's network and hosts.
/// </summary>
public sealed partial class RulesWindow : Window
{
    private readonly RulesModel rules;
    private readonly Dictionary<string, NavigationViewItem> items = [];
    private readonly TaskCompletionSource loaded = new();
    /// <summary>The editor, while it shows. One rule is edited at a time.</summary>
    private ContentDialog? editor;

    public RulesWindow(RulesModel rules)
    {
        this.rules = rules;
        InitializeComponent();
        AppWindow.Resize(new SizeInt32(1040, 820));
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Reqly.ico"));
        WindowLayout.MatchTitleBar(AppWindow);
        foreach (var kind in RuleKinds.All)
        {
            var item = new NavigationViewItem { Content = kind.Title, Tag = kind.Id, Icon = new FontIcon { Glyph = kind.Glyph } };
            items[kind.Id] = item;
            Navigation.MenuItems.Add(item);
        }
        Navigation.SelectedItem = items["breakpoint"];
        Root.Loaded += (_, _) => loaded.TrySetResult();
        rules.Changed += ShowKinds;
        Closed += (_, _) => rules.Changed -= ShowKinds;
        ShowKinds();
    }

    /// <summary>The window's contents, for the self-check's picture of it.</summary>
    public UIElement View => Root;

    /// <summary>The kind of rule the window shows.</summary>
    public string Section => (Navigation.SelectedItem as NavigationViewItem)?.Tag as string ?? "breakpoint";

    public void Show(string kind)
    {
        if (items.TryGetValue(kind, out var item))
        {
            Navigation.SelectedItem = item;
        }
    }

    /// <summary>What the window shows, for the self-check.</summary>
    public string Describe() => Page.Content switch
    {
        RuleListView list => $"{Section}: {list.Describe()}",
        SlowNetworkView network => $"{Section}: {network.Describe()}",
        _ => Section,
    };

    /// <summary>The editor, for the self-check.</summary>
    public ContentDialog? Editor => editor;

    /// <summary>
    /// Opens the editor on a rule, in its kind's section. While another rule is being edited, the
    /// window only comes forward, so the edits you're making aren't lost.
    /// </summary>
    public async Task EditAsync(WireRuleDraft draft)
    {
        Show(draft.Kind);
        await loaded.Task;
        if (editor is not null)
        {
            return;
        }
        editor = draft.Kind == "script"
            ? new ScriptEditorDialog(rules, draft, () => WinRT.Interop.WindowNative.GetWindowHandle(this))
            : new RuleEditorDialog(rules, draft, () => WinRT.Interop.WindowNative.GetWindowHandle(this));
        editor.XamlRoot = Root.XamlRoot;
        try
        {
            await editor.ShowAsync();
        }
        catch (Exception error)
        {
            AppLog.Write($"the rule editor didn't show: {error.Message}");
        }
        finally
        {
            editor = null;
        }
    }

    /// <summary>A dot by each kind that's on, and why the rules can't be read or saved, if they can't.</summary>
    private void ShowKinds()
    {
        foreach (var (kind, item) in items)
        {
            var isOn = rules.IsOn(kind);
            item.InfoBadge = isOn ? new InfoBadge { Style = (Style)Application.Current.Resources["SuccessDotInfoBadgeStyle"] } : null;
            AutomationProperties.SetItemStatus(item, isOn ? "On" : "");
        }
        ProblemBar.Message = rules.Rules.Problem ?? "";
        ProblemBar.IsOpen = rules.Rules.Problem is not null;
    }

    private void OnSectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is not NavigationViewItem { Tag: string kind })
        {
            return;
        }
        PageTitle.Text = RuleKinds.Of(kind).Title;
        Page.Content = kind == "slowNetwork" ? new SlowNetworkView(rules) : new RuleListView(rules, kind, EditAsync);
    }
}
