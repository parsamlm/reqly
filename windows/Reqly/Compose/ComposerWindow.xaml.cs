using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Reqly.Core;
using Reqly.Inspector;
using Windows.Graphics;
using Windows.System;

namespace Reqly.Compose;

/// <summary>
/// A window for writing a request and sending it, as the Mac's composer: the method, the URL, the
/// headers, each of which can be switched off, and the body. The response shows beside it.
/// </summary>
public sealed partial class ComposerWindow : Window
{
    private static readonly string[] CommonMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"];

    private readonly CoreSession session;
    private readonly WireOutgoing draft;
    /// <summary>The exchange the last Send recorded.</summary>
    private ulong? sent;
    private int sends;
    /// <summary>The body as the text box shows it, to tell whether you changed it.</summary>
    private string shownBody = "";

    public ComposerWindow(CoreSession session, WireOutgoing? draft, Action<string> copy)
    {
        this.session = session;
        this.draft = draft ?? new WireOutgoing();
        InitializeComponent();
        AppWindow.Resize(new SizeInt32(1120, 720));
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Reqly.ico"));
        WindowLayout.MatchTitleBar(AppWindow);
        SystemBackdrop = new MicaBackdrop();
        var methods = CommonMethods.Contains(this.draft.Method) ? CommonMethods : [this.draft.Method, .. CommonMethods];
        foreach (var method in methods)
        {
            Method.Items.Add(method);
        }
        Method.SelectedItem = this.draft.Method;
        Method.SelectionChanged += (_, _) => ShowTitle();
        Address.Text = this.draft.Url;
        Address.TextChanged += (_, _) => ShowTitle();
        foreach (var header in this.draft.Headers)
        {
            AddHeaderRow(header);
        }
        ShowBody();
        ShowHeaderCount();
        ShowTitle();
        Response.Attach(new InspectorContext(session, copy, () => WinRT.Interop.WindowNative.GetWindowHandle(this)), null);
        var send = new KeyboardAccelerator { Key = VirtualKey.Enter, Modifiers = VirtualKeyModifiers.Control };
        send.Invoked += (sender, args) =>
        {
            args.Handled = true;
            _ = SendAsync();
        };
        Root.KeyboardAccelerators.Add(send);
    }

    /// <summary>"New request", or the method and the path once there's a URL.</summary>
    private void ShowTitle()
    {
        var path = Uri.TryCreate(Address.Text.Trim(), UriKind.Absolute, out var url) ? url.AbsolutePath : "";
        Title = path.Length > 0 && path != "/" || Address.Text.Trim().Length > "https://".Length
            ? $"{Method.SelectedItem} {(path.Length > 0 ? path : "/")}"
            : "New request";
    }

    private void ShowBody()
    {
        var isBinary = draft.BinaryBody is not null;
        BodyText.Visibility = isBinary ? Visibility.Collapsed : Visibility.Visible;
        BinaryLine.Visibility = isBinary ? Visibility.Visible : Visibility.Collapsed;
        if (isBinary)
        {
            var size = Convert.FromBase64String(draft.BinaryBody!).Length;
            BinaryText.Text = $"This body isn't text: {(size == 1 ? "1 byte" : $"{size:N0} bytes")}. It's sent as it was.";
        }
        else
        {
            BodyText.Text = draft.Body ?? "";
            shownBody = BodyText.Text;
        }
    }

    private void OnRemoveBodyClicked(object sender, RoutedEventArgs e)
    {
        draft.BinaryBody = null;
        draft.Body = "";
        ShowBody();
    }

    // MARK: Headers

    private void OnAddHeaderClicked(object sender, RoutedEventArgs e)
    {
        var header = new WireOutgoingHeader();
        draft.Headers.Add(header);
        AddHeaderRow(header).Focus(FocusState.Programmatic);
        ShowHeaderCount();
    }

    /// <summary>A header's row: whether to send it, its name, its value, and a button that removes it.</summary>
    private TextBox AddHeaderRow(WireOutgoingHeader header)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(170) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var isOn = new CheckBox { IsChecked = header.IsOn, MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
        ToolTipService.SetToolTip(isOn, "Send this header");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(isOn, "Send this header");
        var name = new TextBox { Text = header.Name, PlaceholderText = "Name", FontFamily = Blocks.Mono, FontSize = 12 };
        var value = new TextBox { Text = header.Value, PlaceholderText = "Value", FontFamily = Blocks.Mono, FontSize = 12 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(name, "Header name");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(value, "Header value");
        var remove = Blocks.IconButton("\uE738", "Remove header", () =>
        {
            draft.Headers.Remove(header);
            HeaderRows.Children.Remove(row);
            ShowHeaderCount();
        });
        void Dim() => row.Opacity = header.IsOn ? 1 : 0.6;
        isOn.Click += (_, _) =>
        {
            header.IsOn = isOn.IsChecked == true;
            Dim();
            ShowHeaderCount();
        };
        name.TextChanged += (_, _) => header.Name = name.Text;
        value.TextChanged += (_, _) => header.Value = value.Text;
        Grid.SetColumn(name, 1);
        Grid.SetColumn(value, 2);
        Grid.SetColumn(remove, 3);
        row.Children.Add(isOn);
        row.Children.Add(name);
        row.Children.Add(value);
        row.Children.Add(remove);
        Dim();
        HeaderRows.Children.Add(row);
        return name;
    }

    private void ShowHeaderCount() => HeaderCount.Text = draft.Headers.Count(header => header.IsOn).ToString("N0");

    // MARK: Sending

    private void OnSendClicked(object sender, RoutedEventArgs e) => _ = SendAsync();

    private void OnAddressKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            _ = SendAsync();
        }
    }

    /// <summary>Sends the request as written, then follows its response until it's done.</summary>
    public async Task SendAsync()
    {
        draft.Method = Method.SelectedItem as string ?? "GET";
        draft.Url = Address.Text;
        // A body you didn't change goes as it was, its lines ended as they were.
        if (draft.BinaryBody is null && BodyText.Text != shownBody)
        {
            draft.Body = Blocks.LinesAsIn(BodyText.Text, draft.Body ?? "");
            shownBody = BodyText.Text;
        }
        try
        {
            var request = new JsonObject
            {
                ["call"] = "send",
                ["request"] = JsonSerializer.SerializeToNode(draft, Wire.Options),
            };
            var result = await session.CallAsync(request);
            ProblemLine.Visibility = Visibility.Collapsed;
            sent = result.GetProperty("id").GetUInt64();
        }
        catch (CoreProblem problem)
        {
            ProblemText.Text = problem.Message;
            ProblemLine.Visibility = Visibility.Visible;
            return;
        }
        NothingSent.Visibility = Visibility.Collapsed;
        Response.Visibility = Visibility.Visible;
        var send = ++sends;
        var id = sent.Value;
        // The response comes in after the call returns, so the details follow it until it's done.
        string? shown = null;
        for (var attempt = 0; attempt < 300 && send == sends; attempt++)
        {
            try
            {
                var details = Wire.Read<WireDetails>(await session.CallAsync(new JsonObject { ["call"] = "details", ["id"] = id }));
                var state = $"{details.State} {details.Status} {details.BytesReceived}";
                if (state != shown)
                {
                    shown = state;
                    await Response.ShowAsync(id);
                }
                if (details.State is "completed" or "failed")
                {
                    break;
                }
            }
            catch (CoreProblem)
            {
                // Not recorded yet.
            }
            await Task.Delay(400);
        }
    }

    /// <summary>What the window shows, for the self-check.</summary>
    public string Describe() => $"{Title} · {(ProblemLine.Visibility == Visibility.Visible ? ProblemText.Text : "")} · {(Response.Visibility == Visibility.Visible ? Response.Describe() : "nothing sent")}";

    /// <summary>Sets the URL, as typing it would, for the self-check.</summary>
    public void UseAddress(string url) => Address.Text = url;
}
