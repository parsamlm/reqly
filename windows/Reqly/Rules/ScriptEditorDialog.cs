using System.Text.RegularExpressions;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Reqly.Core;
using Reqly.Inspector;

namespace Reqly.Rules;

/// <summary>
/// The script editor, as the Mac's: what the script matches, its code, checked as you type, and a
/// way to try it on a request captured earlier without sending anything.
/// </summary>
public sealed partial class ScriptEditorDialog : ContentDialog
{
    private static readonly Dictionary<string, string> ExampleTitles = new()
    {
        ["addHeader"] = "Add a header to requests",
        ["changeJSON"] = "Change a JSON response",
        ["answer"] = "Answer without the server",
        ["sendElsewhere"] = "Send requests to another server",
        ["rememberToken"] = "Remember a token from a sign-in",
        ["log"] = "Log what passes",
    };

    private readonly RulesModel rules;
    private readonly WireRuleDraft draft;
    private readonly MatchFields fields;
    private readonly CodeEditor code;
    private readonly FontIcon statusIcon = new() { FontSize = 13, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) };
    private readonly TextBlock statusText = new() { TextWrapping = TextWrapping.Wrap, MaxLines = 2 };
    private readonly HyperlinkButton showLine = new() { Content = "Show the line", Padding = new Thickness(4, 0, 4, 0), MinHeight = 0, Visibility = Visibility.Collapsed };
    private readonly ComboBox requests = new() { MinWidth = 460, PlaceholderText = "No matching requests yet", IsEnabled = false };
    private readonly Button tryButton = new() { Content = "Try it", IsEnabled = false };
    private readonly StackPanel results = new() { Spacing = 8 };
    private readonly MatchLine match = new();
    private WireRuleRequest[] matching = [];
    /// <summary>The script's syntax error, with its line, from the last check.</summary>
    private string? syntaxProblem;
    /// <summary>What else to fix, such as a script with no function to run.</summary>
    private string? draftProblem;
    private bool isChecking;
    private bool isTrying;
    private int syntaxChecks;
    private int draftChecks;

    public ScriptEditorDialog(RulesModel rules, WireRuleDraft draft, Func<IntPtr> window)
    {
        this.rules = rules;
        this.draft = draft;
        Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"];
        Title = Header(draft.IsNew ? "New script" : "Edit script");
        PrimaryButtonText = "Save";
        CloseButtonText = "Cancel";
        // Return goes in the code, so it doesn't save; the button still shows it's the one that does.
        DefaultButton = ContentDialogButton.None;
        PrimaryButtonStyle = (Style)Application.Current.Resources["AccentButtonStyle"];
        IsPrimaryButtonEnabled = false;
        Dialogs.Widen(this, 908);
        fields = new MatchFields(draft, ScheduleDraftCheck);
        var content = new StackPanel { Spacing = 14, Width = 844 };
        content.Children.Add(Dialogs.Columns((fields.Name, Dialogs.Star), (fields.Method, new GridLength(160))));
        content.Children.Add(Dialogs.Columns((fields.Host, Dialogs.Star), (fields.Path, Dialogs.Star)));

        code = new CodeEditor(draft.Code, rules.HighlightScriptAsync, "Script") { Height = 300 };
        code.TextChanged += () =>
        {
            draft.Code = code.Text;
            ShowResults(null);
            ScheduleSyntaxCheck();
            ScheduleDraftCheck();
        };
        content.Children.Add(code);
        var status = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        status.Children.Add(statusIcon);
        status.Children.Add(statusText);
        status.Children.Add(showLine);
        AutomationProperties.SetLiveSetting(statusText, AutomationLiveSetting.Polite);
        showLine.Click += (_, _) => ShowProblemLine();
        content.Children.Add(status);

        var tryRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        tryRow.Children.Add(new TextBlock { Text = "Try it on", VerticalAlignment = VerticalAlignment.Center });
        AutomationProperties.SetName(requests, "Request to try the script on");
        requests.SelectionChanged += (_, _) => ShowStatus();
        tryRow.Children.Add(requests);
        tryButton.Click += async (_, _) => await TryAsync();
        tryRow.Children.Add(tryButton);
        content.Children.Add(tryRow);
        content.Children.Add(new Border
        {
            Background = Blocks.Resource("SubtleFillColorSecondaryBrush"),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(12, 10, 12, 10),
            Child = new ScrollViewer { Content = results, MaxHeight = 150 },
        });
        ShowResults(null);
        content.Children.Add(match.View);
        Content = content;
        PrimaryButtonClick += OnSaveClicked;
        Loaded += async (_, _) =>
        {
            ShowStatus();
            await Task.WhenAll(CheckSyntaxAsync(++syntaxChecks), CheckDraftAsync(++draftChecks));
        };
    }

    /// <summary>What the editor shows, for the self-check.</summary>
    public string Describe() => $"{statusText.Text} · {match.Text} · {requests.Items.Count} to try · {code.ColoredTokens} colored · Save {(IsPrimaryButtonEnabled ? "on" : "off")}";

    /// <summary>The title, with the examples to start from and what scripts can use.</summary>
    private Grid Header(string title)
    {
        var examples = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight };
        foreach (var example in rules.Examples)
        {
            var item = new MenuFlyoutItem { Text = ExampleTitles.GetValueOrDefault(example.Id, example.Id) };
            item.Click += (_, _) => UseExample(example);
            examples.Items.Add(item);
        }
        var examplesButton = new DropDownButton { Content = "Examples", Flyout = examples, VerticalAlignment = VerticalAlignment.Center };
        var reference = new Button
        {
            Content = new FontIcon { Glyph = "", FontSize = 14 },
            Padding = new Thickness(8),
            VerticalAlignment = VerticalAlignment.Center,
            Flyout = new Flyout { Content = Reference(), Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight },
        };
        ToolTipService.SetToolTip(reference, "Script reference");
        AutomationProperties.SetName(reference, "Script reference");
        var header = new Grid { ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = Dialogs.Star });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center });
        Grid.SetColumn(examplesButton, 1);
        Grid.SetColumn(reference, 2);
        header.Children.Add(examplesButton);
        header.Children.Add(reference);
        return header;
    }

    private void UseExample(WireScriptExample example)
    {
        code.Text = example.Code;
        if (fields.Name.Text.Trim().Length == 0)
        {
            fields.Name.Text = ExampleTitles.GetValueOrDefault(example.Id, example.Id);
        }
    }

    /// <summary>What scripts can use, in a few lines.</summary>
    private static StackPanel Reference()
    {
        var panel = new StackPanel { Spacing = 10, Width = 420 };
        panel.Children.Add(new TextBlock { Text = "Scripts", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        void Entry(string name, string text)
        {
            var entry = new StackPanel { Spacing = 2 };
            entry.Children.Add(new TextBlock { Text = name, FontFamily = Blocks.Mono, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            entry.Children.Add(Blocks.Note(text));
            panel.Children.Add(entry);
        }
        Entry("onRequest(request)", "Runs before a matching request goes to the server. Change its method, url, headers or body, or return respond(status, body, headers) to answer it yourself.");
        Entry("onResponse(response, request)", "Runs before a matching response goes back to the app. Change its status, reason, headers or body.");
        Entry("request.json, response.json", "A JSON body, parsed. Change it, and the body changes too.");
        Entry("headers", "Work as in the Fetch API: get, getAll, set, append, delete and has. Go through them with forEach or for…of. Names match in any case.");
        Entry("shared", "Keeps what you put in it from one run of the script to the next, while Reqly runs.");
        Entry("console.log", "Writes to the Overview of the request the script ran on.");
        Entry("atob, btoa", "Decode and encode Base64.");
        panel.Children.Add(Blocks.Note("Each run has 1 second, and can't reach files or the network. A script that fails leaves the traffic as it was."));
        return panel;
    }

    // MARK: Checking

    private async void ScheduleSyntaxCheck()
    {
        var check = ++syntaxChecks;
        isChecking = true;
        ShowStatus();
        await Task.Delay(350);
        if (check == syntaxChecks)
        {
            await CheckSyntaxAsync(check);
        }
    }

    private async Task CheckSyntaxAsync(int check)
    {
        string? found;
        try
        {
            found = await rules.CheckScriptAsync(draft.Code);
        }
        catch (CoreProblem failure)
        {
            AppLog.Write($"couldn't check the script: {failure.Message}");
            return;
        }
        if (check != syntaxChecks)
        {
            return;
        }
        syntaxProblem = found;
        isChecking = false;
        ShowStatus();
    }

    private async void ScheduleDraftCheck()
    {
        var check = ++draftChecks;
        await Task.Delay(150);
        if (check == draftChecks)
        {
            await CheckDraftAsync(check);
        }
    }

    private async Task CheckDraftAsync(int check)
    {
        WireRuleCheck result;
        try
        {
            result = await rules.CheckAsync(draft);
        }
        catch (CoreProblem failure)
        {
            AppLog.Write($"couldn't check the script's rule: {failure.Message}");
            return;
        }
        if (check != draftChecks)
        {
            return;
        }
        draftProblem = result.Problem;
        fields.ShowDefaultName(result.DefaultName);
        match.Show(result.MatchCount);
        ShowRequests(result.Matching ?? []);
        ShowStatus();
    }

    /// <summary>The requests to try the script on, newest first, keeping the one chosen while it's there.</summary>
    private void ShowRequests(WireRuleRequest[] found)
    {
        var chosen = requests.SelectedIndex >= 0 && requests.SelectedIndex < matching.Length ? matching[requests.SelectedIndex].Id : draft.Exchange;
        if (found.Select(request => request.Id).SequenceEqual(matching.Select(request => request.Id)))
        {
            return;
        }
        matching = found;
        requests.Items.Clear();
        foreach (var request in found)
        {
            requests.Items.Add(request.Description);
        }
        var index = Array.FindIndex(found, request => request.Id == chosen);
        requests.SelectedIndex = found.Length == 0 ? -1 : Math.Max(index, 0);
        requests.IsEnabled = found.Length > 0;
    }

    /// <summary>The line under the code: what to fix, or that there's nothing to.</summary>
    private void ShowStatus()
    {
        var problem = syntaxProblem ?? draftProblem;
        if (problem is not null)
        {
            statusIcon.Glyph = "";
            statusIcon.Foreground = Blocks.Resource("SystemFillColorCautionBrush");
            statusText.Text = problem;
        }
        else if (isChecking)
        {
            statusIcon.Glyph = "";
            statusIcon.Foreground = Blocks.Resource("TextFillColorSecondaryBrush");
            statusText.Text = "Checking…";
        }
        else
        {
            statusIcon.Glyph = "";
            statusIcon.Foreground = Blocks.Resource("SystemFillColorSuccessBrush");
            statusText.Text = "No problems";
        }
        showLine.Visibility = ProblemLineNumber() is not null && problem == syntaxProblem ? Visibility.Visible : Visibility.Collapsed;
        IsPrimaryButtonEnabled = draftProblem is null && syntaxProblem is null;
        tryButton.IsEnabled = !isTrying && syntaxProblem is null && requests.SelectedIndex >= 0;
        tryButton.Content = isTrying ? "Trying…" : "Try it";
    }

    /// <summary>The line a syntax error is on, from "…, on line 3."</summary>
    private int? ProblemLineNumber() =>
        syntaxProblem is not null && Regex.Match(syntaxProblem, @"on line (\d+)") is { Success: true } found ? int.Parse(found.Groups[1].Value) : null;

    /// <summary>Puts the cursor at the start of the line with the error.</summary>
    private void ShowProblemLine()
    {
        if (ProblemLineNumber() is not int line)
        {
            return;
        }
        var text = code.Text;
        var start = 0;
        for (var number = 1; number < line; number++)
        {
            var next = text.IndexOf('\n', start);
            if (next < 0)
            {
                break;
            }
            start = next + 1;
        }
        code.Select(start, 0);
    }

    // MARK: Trying

    /// <summary>Tries the script on the request chosen, as Try it does, for the self-check.</summary>
    public Task TryItAsync() => TryAsync();

    /// <summary>Types a comment into the code and undoes it, for the self-check.</summary>
    public Task<string> CheckEditingAsync() => code.CheckTypingAsync("\n// Reqly typed this");

    private async Task TryAsync()
    {
        if (requests.SelectedIndex < 0 || requests.SelectedIndex >= matching.Length)
        {
            return;
        }
        isTrying = true;
        ShowStatus();
        try
        {
            ShowResults(await rules.TryScriptAsync(draft.Code, matching[requests.SelectedIndex].Id));
        }
        catch (CoreProblem failure)
        {
            AppLog.Write($"couldn't try the script: {failure.Message}");
        }
        isTrying = false;
        ShowStatus();
    }

    /// <summary>What the script would do, for each part it runs on, with what it logged.</summary>
    private void ShowResults(WireScriptTrial[]? trials)
    {
        results.Children.Clear();
        if (trials is null)
        {
            results.Children.Add(Blocks.Note("Runs the script on a request captured earlier, and shows what it would change. Nothing is sent."));
            return;
        }
        if (trials.Length == 0)
        {
            results.Children.Add(Blocks.Note("The request isn't there anymore."));
        }
        foreach (var trial in trials)
        {
            var entry = new StackPanel { Spacing = 4 };
            var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            line.Children.Add(new TextBlock { Text = trial.Part == "request" ? "onRequest" : "onResponse", FontFamily = Blocks.Mono, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            line.Children.Add(new TextBlock
            {
                Text = trial.Detail,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
                Foreground = Blocks.Resource(trial.Failed ? "SystemFillColorCautionBrush" : "TextFillColorPrimaryBrush"),
            });
            entry.Children.Add(line);
            if (trial.Logs.Length > 0)
            {
                entry.Children.Add(new TextBlock
                {
                    Text = string.Join("\n", trial.Logs),
                    FontFamily = Blocks.Mono,
                    FontSize = 12,
                    MaxLines = 6,
                    IsTextSelectionEnabled = true,
                    Foreground = Blocks.Resource("TextFillColorSecondaryBrush"),
                });
            }
            results.Children.Add(entry);
        }
    }

    private async void OnSaveClicked(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        var deferral = args.GetDeferral();
        var failure = await rules.SaveAsync(draft);
        if (failure is not null)
        {
            args.Cancel = true;
            draftProblem = failure;
            ShowStatus();
        }
        deferral.Complete();
    }
}
