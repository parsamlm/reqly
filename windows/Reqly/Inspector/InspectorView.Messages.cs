using System.Collections.ObjectModel;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Reqly.Core;
using Reqly.Traffic;

namespace Reqly.Inspector;

/// <summary>The Messages tab, for WebSocket, as the Mac's: the messages, a filter, and the selected message.</summary>
public sealed partial class InspectorView
{
    private async Task<List<UIElement>> MessagesTabAsync(WireDetails shown)
    {
        var parts = new List<UIElement>();
        if (context is null)
        {
            return parts;
        }
        WireMessage[] messages;
        try
        {
            var result = await context.Session.CallAsync(new JsonObject { ["call"] = "messages", ["id"] = shown.Id, ["from"] = 0 });
            messages = Wire.Read<WireMessage[]>(result.GetProperty("messages"));
        }
        catch (CoreProblem problem)
        {
            parts.Add(Blocks.Note(problem.Message));
            return parts;
        }
        if (messages.Length == 0)
        {
            var empty = Blocks.Section("Messages");
            empty.Children.Add(Blocks.Note(shown.State == "open" ? "No messages yet." : "The connection didn't carry any messages."));
            parts.Add(empty);
            return parts;
        }

        var rows = new ObservableCollection<MessageRow>(messages.Select(message => new MessageRow(message, shown.Started)));
        var filter = new TextBox { PlaceholderText = "Filter messages", MinHeight = 0 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(filter, "Filter messages");
        var directions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        var direction = "all";
        // On a row of their own, under the title, so they fit however narrow the details are.
        var tools = new Grid { ColumnSpacing = 8 };
        tools.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        tools.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        tools.Children.Add(filter);
        Grid.SetColumn(directions, 1);
        tools.Children.Add(directions);
        var section = Blocks.Section("Messages", messages.Length);
        section.Children.Add(tools);
        var list = new ListView
        {
            ItemsSource = rows,
            SelectionMode = ListViewSelectionMode.Single,
            MaxHeight = Math.Max(160, ViewerHeight * 0.5),
            BorderThickness = new Thickness(1),
            BorderBrush = Blocks.Resource("CardStrokeColorDefaultBrush"),
            CornerRadius = new CornerRadius(10),
            ItemTemplate = (DataTemplate)Resources["MessageRowTemplate"],
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(list, "Messages");
        var nothing = Blocks.Note("No messages match.");
        nothing.Visibility = Visibility.Collapsed;
        void Narrow()
        {
            var text = filter.Text.Trim();
            rows.Clear();
            foreach (var message in messages)
            {
                var matchesText = text.Length == 0
                    || (message.Kind is "text" or "close" && (message.Text ?? "").Contains(text, StringComparison.CurrentCultureIgnoreCase));
                if (matchesText && (direction == "all" || message.Direction == direction))
                {
                    rows.Add(new MessageRow(message, shown.Started));
                }
            }
            nothing.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        var buttons = new List<ToggleButton>();
        foreach (var (name, title) in new[] { ("all", "All"), ("sent", "Sent"), ("received", "Received") })
        {
            var button = new ToggleButton { Content = title, IsChecked = name == direction, Padding = new Thickness(10, 2, 10, 3), MinHeight = 0, MinWidth = 0, FontSize = 12 };
            button.Click += (_, _) =>
            {
                direction = name;
                buttons.ForEach(other => other.IsChecked = other == button);
                Narrow();
            };
            buttons.Add(button);
            directions.Children.Add(button);
        }
        filter.TextChanged += (_, _) => Narrow();
        section.Children.Add(list);
        section.Children.Add(nothing);
        parts.Add(section);

        var detail = new StackPanel { Spacing = 8 };
        parts.Add(detail);
        list.SelectionChanged += async (_, _) =>
        {
            if (list.SelectedItem is MessageRow row)
            {
                await ShowMessageAsync(shown, row.Message, detail);
            }
        };
        return parts;
    }

    /// <summary>The selected message, with a viewer that suits what it holds, as for a body.</summary>
    private async Task ShowMessageAsync(WireDetails shown, WireMessage message, StackPanel detail)
    {
        if (context is null)
        {
            return;
        }
        detail.Children.Clear();
        var time = DateTime.UnixEpoch.AddSeconds(message.Time).ToLocalTime();
        detail.Children.Add(Blocks.Note(
            $"Message {message.Number + 1:N0} · {(message.Direction == "sent" ? "Sent" : "Received")} · {MessageRow.KindTitle(message.Kind)} · {time:HH:mm:ss.fff}"));
        if (message.Size > message.KeptSize)
        {
            detail.Children.Add(Blocks.Note($"Reqly kept the first {Bytes(message.KeptSize)} of {Bytes(message.Size)}."));
        }
        if (message.KeptSize == 0)
        {
            detail.Children.Add(Blocks.Note(message.Kind == "close" ? "This close message has no reason." : "This message is empty."));
            return;
        }
        try
        {
            var body = Wire.Read<WireBody>(await context.Session.CallAsync(new JsonObject { ["call"] = "presentMessage", ["id"] = shown.Id, ["number"] = message.Number }));
            if ((body.Formatted ?? body.Raw) is { } code)
            {
                detail.Children.Add(new CodeView(code, ViewerHeight));
            }
            else
            {
                detail.Children.Add(Blocks.Note($"{body.Kind} · {Format.Size(body.Size)}"));
            }
        }
        catch (CoreProblem problem)
        {
            detail.Children.Add(Blocks.Note(problem.Message));
        }
    }

    private static string Bytes(int count) => count == 1 ? "1 byte" : $"{count:N0} bytes";
}

/// <summary>A message's row: which way it went, its kind, its start, its size and when it came.</summary>
public sealed class MessageRow(WireMessage message, double started)
{
    public WireMessage Message { get; } = message;
    public string Arrow => Message.Direction == "sent" ? "\uE74A" : "\uE74B";
    public string Kind => KindTitle(Message.Kind);
    public string Preview => Message.Preview;
    public string Size => Format.Size(Message.Size);
    public string Time => "+" + Format.Duration(Message.Time - started);
    public string Tip => Message.Direction == "sent" ? "Sent by the app" : "Received from the server";

    public static string KindTitle(string kind) => kind switch
    {
        "text" => "Text",
        "binary" => "Binary",
        "close" => "Close",
        "ping" => "Ping",
        _ => "Pong",
    };

    public override string ToString() => $"{(Message.Direction == "sent" ? "Sent" : "Received")} {Kind.ToLowerInvariant()}, {Preview}";
}
