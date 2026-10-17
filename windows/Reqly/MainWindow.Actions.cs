using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Shapes;
using Reqly.Core;
using Reqly.Traffic;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Streams;

namespace Reqly;

/// <summary>What you can do with one request, from its menu in the list or a shortcut, as on the Mac.</summary>
public sealed partial class MainWindow
{
    /// <summary>The menu for the row you right-clicked, which may not be the selected one.</summary>
    private async void OnListContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        var row = (args.OriginalSource as FrameworkElement)?.DataContext as RequestRow
            ?? (args.OriginalSource as ListViewItem)?.Content as RequestRow;
        if (row?.Contents is null)
        {
            return;
        }
        args.Handled = true;
        var menu = await MenuAsync(row);
        if (args.TryGetPosition(List, out var point))
        {
            menu.ShowAt(List, point);
        }
        else
        {
            menu.ShowAt(List, new Microsoft.UI.Xaml.Controls.Primitives.FlyoutShowOptions());
        }
    }

    private async Task<MenuFlyout> MenuAsync(RequestRow row)
    {
        var menu = new MenuFlyout();
        // An encrypted connection has no request to copy.
        var isReadable = row.IsReadable;
        menu.Items.Add(Item("Copy URL", () => _ = CopyUrlAsync(row), shortcut: "Ctrl+Shift+C"));
        menu.Items.Add(Item("Copy as cURL", () => _ = CopyCurlAsync(row), isReadable, "Ctrl+Alt+C"));
        menu.Items.Add(Item("Copy response body", () => _ = CopyResponseBodyAsync(row), isReadable && row.Contents?.Status is not null));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item("Resend", () => _ = ResendAsync(row), isReadable));
        menu.Items.Add(Item("Edit and resend…", () => _ = EditAndResendAsync(row), isReadable));
        menu.Items.Add(AddRuleMenu(row: row));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(row.IsPinned ? "Unpin request" : "Pin request", () => _ = AnnotateAsync(row, new JsonObject { ["isPinned"] = !row.IsPinned })));
        var colors = new MenuFlyoutSubItem { Text = "Color" };
        colors.Items.Add(ColorItem(row, null));
        colors.Items.Add(new MenuFlyoutSeparator());
        foreach (var color in Palette.MarkColors)
        {
            colors.Items.Add(ColorItem(row, color));
        }
        menu.Items.Add(colors);
        menu.Items.Add(Item(row.Comment is null ? "Add comment…" : "Edit comment…", () => _ = EditCommentAsync(row)));
        // HTTPS is all there is to decrypt, from a tunnel or a request already decrypted.
        if (https is not null && row.Contents?.Scheme == "https")
        {
            var host = row.Host;
            var decrypts = await https.DecryptsAsync(host);
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(Item(
                decrypts ? $"Stop decrypting {host}" : $"Decrypt {host}",
                () => _ = decrypts ? https.StopDecryptingAsync(host) : https.DecryptAsync(host)));
        }
        return menu;
    }

    private static MenuFlyoutItem Item(string text, Action action, bool isEnabled = true, string? shortcut = null)
    {
        var item = new MenuFlyoutItem { Text = text, IsEnabled = isEnabled };
        if (shortcut is not null)
        {
            item.KeyboardAcceleratorTextOverride = shortcut;
        }
        item.Click += (_, _) => action();
        return item;
    }

    /// <summary>A color for the request, with a dot in it, and a check by the one it has.</summary>
    private RadioMenuFlyoutItem ColorItem(RequestRow row, string? color)
    {
        var item = new RadioMenuFlyoutItem
        {
            Text = color is null ? "None" : Palette.MarkName(color),
            GroupName = "Color",
            IsChecked = row.Color == color,
        };
        if (color is not null)
        {
            item.Icon = new PathIcon
            {
                Data = new Microsoft.UI.Xaml.Media.EllipseGeometry { Center = new Windows.Foundation.Point(6, 6), RadiusX = 5, RadiusY = 5 },
                Foreground = Palette.Mark(color),
            };
        }
        item.Click += (_, _) => _ = AnnotateAsync(row, new JsonObject { ["color"] = color is null ? null : JsonValue.Create(color) });
        return item;
    }

    private async Task AnnotateAsync(RequestRow row, JsonObject change)
    {
        if (session is null)
        {
            return;
        }
        change["call"] = "annotate";
        change["id"] = row.ID;
        try
        {
            await session.CallAsync(change);
        }
        catch (CoreProblem problem)
        {
            Log($"couldn't annotate: {problem.Message}");
        }
    }

    /// <summary>Selects the request and starts editing its comment in the details, as on the Mac.</summary>
    private async Task EditCommentAsync(RequestRow row)
    {
        selectedExchange = row.ID;
        isRestoringSelection = true;
        List.SelectedItem = row;
        isRestoringSelection = false;
        shownState = StateOf(row);
        await Inspector.ShowAsync(row.ID);
        Inspector.EditComment();
    }

    // MARK: Copying

    /// <summary>The request's address, such as https://api.example.com/v1/forecast?city=Lisbon.</summary>
    private static string Url(RequestRow row)
    {
        var contents = row.Contents!;
        var host = contents.Host.Contains(':') ? $"[{contents.Host}]" : contents.Host;
        var isDefaultPort = (contents.Scheme, contents.Port) is ("http", 80) or ("https", 443);
        var authority = isDefaultPort ? host : $"{host}:{contents.Port}";
        return $"{contents.Scheme}://{authority}{(row.IsTunnel ? "" : contents.Target)}";
    }

    private Task CopyUrlAsync(RequestRow? row)
    {
        if (row?.Contents is not null)
        {
            CopyText(Url(row));
        }
        return Task.CompletedTask;
    }

    private async Task CopyCurlAsync(RequestRow? row)
    {
        if (session is null || row is not { IsReadable: true })
        {
            return;
        }
        try
        {
            var result = await session.CallAsync(new JsonObject { ["call"] = "curl", ["id"] = row.ID });
            CopyText(result.GetProperty("command").GetString() ?? "");
        }
        catch (CoreProblem problem)
        {
            Log($"couldn't copy as cURL: {problem.Message}");
        }
    }

    /// <summary>The body unpacked: as text when it's text, as an image when it's an image, and otherwise as hex.</summary>
    private async Task CopyResponseBodyAsync(RequestRow row)
    {
        if (session is null)
        {
            return;
        }
        try
        {
            var result = await session.CallAsync(new JsonObject { ["call"] = "copyableBody", ["id"] = row.ID });
            if (result.TryGetProperty("image", out var image) && image.GetString() is { } base64)
            {
                var stream = new InMemoryRandomAccessStream();
                using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
                {
                    writer.WriteBytes(Convert.FromBase64String(base64));
                    await writer.StoreAsync();
                    await writer.FlushAsync();
                }
                if (options.SmokeReport is null)
                {
                    var package = new DataPackage();
                    package.SetBitmap(RandomAccessStreamReference.CreateFromStream(stream));
                    Clipboard.SetContent(package);
                }
            }
            else if (result.TryGetProperty("text", out var text) && text.GetString() is { } body)
            {
                CopyText(body);
            }
            else if (result.TryGetProperty("hex", out var hex) && hex.GetString() is { } bytes)
            {
                CopyText(bytes);
            }
        }
        catch (CoreProblem problem)
        {
            Log($"couldn't copy the body: {problem.Message}");
        }
    }

    private void CopyText(string text)
    {
        lastCopied = text;
        // The self-check runs on your desktop, and leaves your clipboard alone.
        if (options.SmokeReport is not null)
        {
            return;
        }
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
    }

    /// <summary>What was copied last, for the self-check, which can't read the clipboard from a test run.</summary>
    private string? lastCopied;
}
