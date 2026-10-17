using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Win32;
using Reqly.Core;
using Reqly.Inspector;
using Windows.Storage.Pickers;

namespace Reqly.Rules;

/// <summary>
/// The editor for a rule other than a script, as the Mac's: what it matches, what it does, and how
/// many requests captured so far it would act on. Save stays off until the rule is complete, and
/// the line under the fields says what's missing.
/// </summary>
public sealed partial class RuleEditorDialog : ContentDialog
{
    private static readonly (string Change, string Title)[] Changes =
    [
        ("setHeader", "Set header"), ("removeHeader", "Remove header"), ("setQueryParameter", "Set query parameter"),
        ("removeQueryParameter", "Remove query parameter"), ("replaceBody", "Replace body text"), ("setStatus", "Set status"),
    ];

    private readonly RulesModel rules;
    private readonly WireRuleDraft draft;
    private readonly Func<IntPtr> window;
    private readonly MatchFields fields;
    private readonly MatchLine match = new();
    private readonly ProblemLine problem = new();
    /// <summary>The latest check, so an answer to an older one doesn't show.</summary>
    private int checks;

    // Map Local's fields, which saving the response fills in.
    private TextBox? file;
    private NumberBox? status;
    private TextBox? contentType;
    private HyperlinkButton? saveResponse;
    private TextBlock? compressionNote;

    public RuleEditorDialog(RulesModel rules, WireRuleDraft draft, Func<IntPtr> window)
    {
        this.rules = rules;
        this.draft = draft;
        this.window = window;
        Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"];
        Title = $"{(draft.IsNew ? "New" : "Edit")} {RuleKinds.Of(draft.Kind).RuleTitle}";
        PrimaryButtonText = "Save";
        CloseButtonText = "Cancel";
        DefaultButton = ContentDialogButton.Primary;
        IsPrimaryButtonEnabled = false;
        var width = draft.Kind == "rewrite" ? 700 : 500;
        // The dialog's own padding and border take the rest.
        Dialogs.Widen(this, width + 64);
        fields = new MatchFields(draft, ScheduleCheck);
        var content = new StackPanel { Spacing = 14, Width = width };
        content.Children.Add(fields.Name);
        content.Children.Add(Dialogs.Columns((fields.Host, Dialogs.Star), (fields.Path, Dialogs.Star)));
        content.Children.Add(fields.Method);
        switch (draft.Kind)
        {
            case "breakpoint": AddBreakpointFields(content); break;
            case "mapLocal": AddMapLocalFields(content); break;
            case "mapRemote": AddMapRemoteFields(content); break;
            case "rewrite": AddRewriteFields(content); break;
            case "block": AddBlockFields(content); break;
        }
        var footer = new StackPanel { Spacing = 8, Margin = new Thickness(0, 6, 0, 0) };
        footer.Children.Add(match.View);
        footer.Children.Add(problem.View);
        content.Children.Add(footer);
        Content = content;
        PrimaryButtonClick += OnSaveClicked;
        Loaded += async (_, _) =>
        {
            await CheckAsync(++checks);
            await ShowSaveResponseAsync();
        };
    }

    /// <summary>What the editor shows, for the self-check.</summary>
    public string Describe() => $"{Title} · {match.Text} · {problem.Problem ?? "no problem"} · Save {(IsPrimaryButtonEnabled ? "on" : "off")}";

    // MARK: Checking

    /// <summary>Checks the draft a moment after the last change, so typing isn't slowed.</summary>
    private async void ScheduleCheck()
    {
        var check = ++checks;
        await Task.Delay(150);
        if (check == checks)
        {
            await CheckAsync(check);
        }
    }

    private async Task CheckAsync(int check)
    {
        WireRuleCheck result;
        try
        {
            result = await rules.CheckAsync(draft);
        }
        catch (CoreProblem failure)
        {
            AppLog.Write($"couldn't check the rule: {failure.Message}");
            return;
        }
        if (check != checks)
        {
            return;
        }
        fields.ShowDefaultName(result.DefaultName);
        match.Show(result.MatchCount);
        problem.Show(result.Problem);
        IsPrimaryButtonEnabled = result.Problem is null;
    }

    private async void OnSaveClicked(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        var deferral = args.GetDeferral();
        var failure = await rules.SaveAsync(draft);
        if (failure is not null)
        {
            args.Cancel = true;
            problem.Show(failure);
        }
        deferral.Complete();
    }

    // MARK: Each kind's fields

    private void AddBreakpointFields(StackPanel content)
    {
        var pause = new RadioButtons { Header = "Pause", MaxColumns = 3 };
        foreach (var phase in new[] { "Request", "Response", "Both" })
        {
            pause.Items.Add(phase);
        }
        pause.SelectedIndex = draft.Phase switch { "request" => 0, "response" => 1, _ => 2 };
        pause.SelectionChanged += (_, _) =>
        {
            draft.Phase = pause.SelectedIndex switch { 0 => "request", 1 => "response", _ => "both" };
            ScheduleCheck();
        };
        content.Children.Add(pause);
    }

    private void AddMapLocalFields(StackPanel content)
    {
        file = new TextBox { Header = Blocks.FieldHeader("File"), PlaceholderText = @"C:\Responses\forecast.json", FontFamily = Blocks.Mono, Text = draft.File };
        file.TextChanged += (_, _) =>
        {
            draft.File = file.Text;
            ScheduleCheck();
        };
        var choose = new Button { Content = "Choose…", VerticalAlignment = VerticalAlignment.Bottom };
        choose.Click += async (_, _) => await ChooseFileAsync();
        content.Children.Add(Dialogs.Columns((file, Dialogs.Star), (choose, GridLength.Auto)));
        saveResponse = new HyperlinkButton { Content = "Save the response as a file…", Visibility = Visibility.Collapsed, Padding = new Thickness(0, 2, 0, 2) };
        saveResponse.Click += async (_, _) => await SaveResponseAsync();
        content.Children.Add(saveResponse);
        status = StatusBox(draft.Status, value => draft.Status = value);
        contentType = new TextBox { Header = "Content type", PlaceholderText = "From the file's extension", Text = draft.ContentType };
        contentType.TextChanged += (_, _) =>
        {
            draft.ContentType = contentType.Text;
            ScheduleCheck();
        };
        content.Children.Add(Dialogs.Columns((status, new GridLength(120)), (contentType, Dialogs.Star)));
    }

    private void AddMapRemoteFields(StackPanel content)
    {
        var destination = new TextBox
        {
            Header = Blocks.FieldHeader("Send to"),
            PlaceholderText = "https://staging.example.com",
            FontFamily = Blocks.Mono,
            Text = draft.Destination,
            Description = Blocks.FieldDescription("A path here replaces the request's path. The query stays."),
        };
        destination.TextChanged += (_, _) =>
        {
            draft.Destination = destination.Text;
            ScheduleCheck();
        };
        content.Children.Add(destination);
    }

    private void AddBlockFields(StackPanel content)
    {
        var answer = new RadioButtons { Header = "Answer" };
        answer.Items.Add("With a status");
        answer.Items.Add("By closing the connection, as a failing network would");
        answer.SelectedIndex = draft.ClosesConnection ? 1 : 0;
        var code = StatusBox(draft.BlockStatus, value => draft.BlockStatus = value);
        // Under the field, not its description, so the field stays narrow and the note wraps.
        var note = Blocks.FieldDescription("HTTPS paths show only for hosts Reqly decrypts. Elsewhere, a rule for any path blocks the host.");
        void ShowAnswer()
        {
            code.IsEnabled = !draft.ClosesConnection;
            note.Foreground = Blocks.Resource(draft.ClosesConnection ? "TextFillColorDisabledBrush" : "TextFillColorSecondaryBrush");
        }
        ShowAnswer();
        answer.SelectionChanged += (_, _) =>
        {
            draft.ClosesConnection = answer.SelectedIndex == 1;
            ShowAnswer();
            ScheduleCheck();
        };
        content.Children.Add(answer);
        content.Children.Add(new StackPanel { Spacing = 4, Children = { code, note } });
    }

    /// <summary>A status code's field. It takes what you type when you press Enter or leave it.</summary>
    private NumberBox StatusBox(int value, Action<int> set)
    {
        var box = new NumberBox
        {
            Header = "Status",
            Value = value,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Hidden,
            HorizontalAlignment = HorizontalAlignment.Left,
            MinWidth = 120,
            NumberFormatter = new Windows.Globalization.NumberFormatting.DecimalFormatter { FractionDigits = 0, IsGrouped = false },
        };
        box.ValueChanged += (_, _) =>
        {
            set(double.IsNaN(box.Value) ? 0 : (int)Math.Round(box.Value));
            ScheduleCheck();
        };
        return box;
    }

    // MARK: Rewrite's changes

    private void AddRewriteFields(StackPanel content)
    {
        var section = new StackPanel { Spacing = 8 };
        section.Children.Add(new TextBlock { Text = "Changes" });
        var rows = new StackPanel { Spacing = 8 };
        foreach (var change in draft.Changes)
        {
            rows.Children.Add(ChangeRow(change, rows));
        }
        section.Children.Add(rows);
        var add = new Button { Style = (Style)Application.Current.Resources["SubtleButtonStyle"] };
        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        label.Children.Add(new FontIcon { Glyph = "\uE710", FontSize = 12 });
        label.Children.Add(new TextBlock { Text = "Add change" });
        add.Content = label;
        add.Click += (_, _) =>
        {
            var change = new WireRewriteChange();
            draft.Changes.Add(change);
            rows.Children.Add(ChangeRow(change, rows));
            ScheduleCheck();
        };
        section.Children.Add(add);
        compressionNote = Blocks.Note("Reqly asks servers not to compress the bodies it changes.");
        section.Children.Add(compressionNote);
        ShowCompressionNote();
        content.Children.Add(section);
    }

    private void ShowCompressionNote()
    {
        if (compressionNote is not null)
        {
            compressionNote.Visibility = draft.Changes.Any(change => change.Change == "replaceBody") ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    /// <summary>One change: what it changes, in the request or the response, and how.</summary>
    private Grid ChangeRow(WireRewriteChange change, StackPanel rows)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(200) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = Dialogs.Star });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var type = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(type, "Change");
        foreach (var (_, title) in Changes)
        {
            type.Items.Add(title);
        }
        type.SelectedIndex = Math.Max(Array.FindIndex(Changes, entry => entry.Change == change.Change), 0);
        var part = new ComboBox { MinWidth = 120 };
        AutomationProperties.SetName(part, "Request or response");
        part.Items.Add("Request");
        part.Items.Add("Response");
        part.SelectedIndex = change.Part == "response" ? 1 : 0;
        part.SelectionChanged += (_, _) =>
        {
            change.Part = part.SelectedIndex == 1 ? "response" : "request";
            ScheduleCheck();
        };
        var values = new Grid { ColumnSpacing = 8 };
        var remove = Blocks.IconButton("\uE738", "Remove change", () =>
        {
            draft.Changes.Remove(change);
            rows.Children.Remove(row);
            ShowCompressionNote();
            ScheduleCheck();
        });
        remove.VerticalAlignment = VerticalAlignment.Center;
        void ShowValues()
        {
            part.Visibility = change.HasPart ? Visibility.Visible : Visibility.Collapsed;
            values.Children.Clear();
            values.ColumnDefinitions.Clear();
            if (change.Change == "setStatus")
            {
                var code = new NumberBox
                {
                    Value = change.Status,
                    SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Hidden,
                    HorizontalAlignment = HorizontalAlignment.Left,
                    MinWidth = 100,
                    NumberFormatter = new Windows.Globalization.NumberFormatting.DecimalFormatter { FractionDigits = 0, IsGrouped = false },
                };
                AutomationProperties.SetName(code, "Status");
                code.ValueChanged += (_, _) =>
                {
                    change.Status = double.IsNaN(code.Value) ? 0 : (int)Math.Round(code.Value);
                    ScheduleCheck();
                };
                values.Children.Add(code);
                return;
            }
            var (first, second) = change.Change switch
            {
                "setHeader" => ("Header", "Value"),
                "removeHeader" => ("Header", null),
                "setQueryParameter" => ("Parameter", "Value"),
                "removeQueryParameter" => ("Parameter", null),
                _ => ("Find", (string?)"Replace with"),
            };
            var name = new TextBox { PlaceholderText = first, Text = change.Name, FontFamily = Blocks.Mono };
            AutomationProperties.SetName(name, first);
            name.TextChanged += (_, _) =>
            {
                change.Name = name.Text;
                ScheduleCheck();
            };
            values.ColumnDefinitions.Add(new ColumnDefinition { Width = Dialogs.Star });
            values.Children.Add(name);
            if (second is not null)
            {
                var value = new TextBox { PlaceholderText = second, Text = change.Value, FontFamily = Blocks.Mono };
                AutomationProperties.SetName(value, second);
                value.TextChanged += (_, _) =>
                {
                    change.Value = value.Text;
                    ScheduleCheck();
                };
                values.ColumnDefinitions.Add(new ColumnDefinition { Width = Dialogs.Star });
                Grid.SetColumn(value, 1);
                values.Children.Add(value);
            }
        }
        type.SelectionChanged += (_, _) =>
        {
            change.Change = Changes[Math.Max(type.SelectedIndex, 0)].Change;
            ShowValues();
            ShowCompressionNote();
            ScheduleCheck();
        };
        ShowValues();
        Grid.SetColumn(part, 1);
        Grid.SetColumn(values, 2);
        Grid.SetColumn(remove, 3);
        row.Children.Add(type);
        row.Children.Add(part);
        row.Children.Add(values);
        row.Children.Add(remove);
        return row;
    }

    // MARK: Map Local's file

    private async Task ChooseFileAsync()
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, window());
        if (await picker.PickSingleFileAsync() is { } chosen && file is not null)
        {
            file.Text = chosen.Path;
        }
    }

    /// <summary>Offers to save the response when the rule was made from a request that has one.</summary>
    private async Task ShowSaveResponseAsync()
    {
        if (saveResponse is null || draft.Exchange is not ulong id)
        {
            return;
        }
        try
        {
            var details = Wire.Read<WireDetails>(await rules.Session.CallAsync(new JsonObject { ["call"] = "details", ["id"] = id }));
            saveResponse.Visibility = !details.IsTunnel && details.Status is not null ? Visibility.Visible : Visibility.Collapsed;
        }
        catch (CoreProblem)
        {
            // The request isn't there anymore.
        }
    }

    /// <summary>Saves the response as it arrived, unpacked, so you can change the file and answer with it.</summary>
    private async Task SaveResponseAsync()
    {
        if (draft.Exchange is not ulong id || file is null || status is null || contentType is null)
        {
            return;
        }
        WireDetails details;
        try
        {
            details = Wire.Read<WireDetails>(await rules.Session.CallAsync(new JsonObject { ["call"] = "details", ["id"] = id }));
        }
        catch (CoreProblem)
        {
            problem.Show("The request isn't there anymore.");
            return;
        }
        var body = await rules.Session.BodyAsync(id, request: false, 0, int.MaxValue, unpacked: true) ?? [];
        var type = details.ResponseHeaders?.FirstOrDefault(header => header.Name.Equals("Content-Type", StringComparison.OrdinalIgnoreCase))?.Value;
        var name = FileName(details, type);
        var picker = new FileSavePicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary, SuggestedFileName = System.IO.Path.GetFileNameWithoutExtension(name) };
        var extension = System.IO.Path.GetExtension(name);
        picker.FileTypeChoices.Add("Response", [extension.Length > 1 ? extension : ".bin"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, window());
        if (await picker.PickSaveFileAsync() is not { } chosen)
        {
            return;
        }
        try
        {
            await System.IO.File.WriteAllBytesAsync(chosen.Path, body);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            problem.Show($"Reqly couldn't save the response. {error.Message}");
            return;
        }
        file.Text = chosen.Path;
        status.Value = details.Status ?? 200;
        contentType.Text = type ?? "";
    }

    /// <summary>A name for a response's file, such as forecast.json: the last part of its path, or its host.</summary>
    private static string FileName(WireDetails details, string? type)
    {
        var last = details.Path.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "";
        var name = Uri.UnescapeDataString(last);
        if (name.Length == 0)
        {
            name = details.Host;
        }
        foreach (var invalid in System.IO.Path.GetInvalidFileNameChars())
        {
            name = name.Replace(invalid, '-');
        }
        return System.IO.Path.HasExtension(name) ? name : name + (Extension(type) ?? "");
    }

    /// <summary>The extension Windows gives files of a type, such as .json for application/json.</summary>
    private static string? Extension(string? contentType)
    {
        var type = contentType?.Split(';')[0].Trim().ToLowerInvariant();
        if (string.IsNullOrEmpty(type))
        {
            return null;
        }
        try
        {
            using var key = Registry.ClassesRoot.OpenSubKey($@"MIME\Database\Content Type\{type}");
            if (key?.GetValue("Extension") is string known && known.StartsWith('.'))
            {
                return known;
            }
        }
        catch (Exception error) when (error is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            // Windows doesn't know it; the list below may.
        }
        return type switch
        {
            "application/json" => ".json",
            "text/html" => ".html",
            "text/plain" => ".txt",
            "text/css" => ".css",
            "text/javascript" or "application/javascript" => ".js",
            "text/xml" or "application/xml" => ".xml",
            "image/png" => ".png",
            "image/jpeg" => ".jpg",
            "image/gif" => ".gif",
            "image/webp" => ".webp",
            "image/svg+xml" => ".svg",
            "application/pdf" => ".pdf",
            _ when type.EndsWith("+json") => ".json",
            _ when type.EndsWith("+xml") => ".xml",
            _ => null,
        };
    }
}
