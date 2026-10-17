using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Reqly.Core;
using Reqly.Traffic;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Reqly.Inspector;

/// <summary>What the details pane's parts need from the window: the session, copying, and the window itself, for file pickers.</summary>
public sealed record InspectorContext(CoreSession Session, Action<string> Copy, Func<nint> WindowHandle);

/// <summary>
/// A body, as the Mac's body section shows it: what it is and its size, a picker for the ways to
/// view it, a copy button, the view, and footnotes about unpacking, gRPC and cut-off bodies.
/// </summary>
public sealed class BodyView : StackPanel
{
    private readonly InspectorContext context;
    private readonly ulong exchange;
    private readonly bool isRequest;
    private readonly WireBody body;
    private readonly double maxHeight;
    /// <summary>The request's path, which names an image's file.</summary>
    private readonly string? path;
    private readonly ContentControl view = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, IsTabStop = false };
    private string mode;
    private byte[]? bytes;
    private HexView? hex;

    /// <summary>Text the Mac shows for each way to view a body.</summary>
    private static string Title(string mode, WireBody body) => mode switch
    {
        "formatted" => "Formatted",
        "tree" => "Tree",
        // Plain text reads as Text; JSON, XML, HTML and forms show as Raw.
        "raw" => body.Raw is { IsCode: false } && body.Fields is null ? "Text" : "Raw",
        "preview" => "Preview",
        "form" => "Form",
        _ => "Hex",
    };

    public BodyView(InspectorContext context, ulong exchange, bool isRequest, WireBody body, double maxHeight, string? path = null)
    {
        this.context = context;
        this.exchange = exchange;
        this.isRequest = isRequest;
        this.body = body;
        this.maxHeight = maxHeight;
        this.path = path;
        Spacing = 8;
        mode = body.Modes.Contains("formatted") ? "formatted" : body.Modes.FirstOrDefault() ?? "hex";

        // The title, what the body is and its size, and Copy; then, below, the ways to view it,
        // which a narrow pane has no room for on the same line.
        var header = new Grid { ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new TextBlock { Text = "Body", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], VerticalAlignment = VerticalAlignment.Center });
        var summary = new TextBlock { Text = Summary(body), Foreground = Blocks.Resource("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        Grid.SetColumn(summary, 1);
        header.Children.Add(summary);
        var copy = Blocks.IconButton("\uE8C8", "Copy body", () => _ = CopyAsync());
        Grid.SetColumn(copy, 2);
        header.Children.Add(copy);
        Children.Add(header);
        // The ways to view it, and for a protobuf body, the message type it's read as.
        var tools = new Grid { ColumnSpacing = 8 };
        tools.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        tools.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (body.Modes.Length > 1)
        {
            tools.Children.Add(ModePicker());
        }
        var protobuf = App.Current.Main?.Protobuf;
        if (body.ReadsAsProtobuf && protobuf is not null)
        {
            var menu = MessageTypeMenu(protobuf);
            Grid.SetColumn(menu, 1);
            tools.Children.Add(menu);
        }
        if (tools.Children.Count > 0)
        {
            Children.Add(tools);
        }
        if (body.ReadsAsProtobuf && body.ProtobufType is null && protobuf is not null)
        {
            Children.Add(SchemaHint(protobuf));
        }

        if (body.Note is { } note)
        {
            var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            line.Children.Add(new FontIcon { Glyph = "\uE946", FontSize = 12, Foreground = Blocks.Resource("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 3, 0, 0) });
            line.Children.Add(new TextBlock { Text = note, TextWrapping = TextWrapping.Wrap, Foreground = Blocks.Resource("TextFillColorSecondaryBrush"), MaxWidth = 560 });
            Children.Add(line);
        }
        Children.Add(view);
        foreach (var footnote in Footnotes(body))
        {
            Children.Add(new TextBlock
            {
                Text = footnote,
                TextWrapping = TextWrapping.Wrap,
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Foreground = Blocks.Resource("TextFillColorSecondaryBrush"),
            });
        }
        _ = ShowAsync();
    }

    /// <summary>"JSON · 4.1 KB", or for gRPC, "gRPC · 3 messages · 1.2 KB".</summary>
    private static string Summary(WireBody body)
    {
        var parts = new List<string> { body.Kind };
        if (body.MessageCount is int count)
        {
            parts.Add(count == 1 ? "1 message" : $"{count:N0} messages");
        }
        parts.Add(Format.Size(body.WireSize));
        return string.Join(" · ", parts);
    }

    private static IEnumerable<string> Footnotes(WireBody body)
    {
        if (body.Grpc is { } grpc)
        {
            yield return $"gRPC status: {grpc.Code} {grpc.Name}" + (grpc.Message is { } message ? $". {message}" : "");
        }
        foreach (var detail in body.Details)
        {
            yield return detail;
        }
        if (body.UnpackedFrom is { } encoding)
        {
            yield return $"Unpacked from {encoding}: {Format.Size(body.WireSize)} became {Format.Size(body.Size)}.";
        }
        if (body.IsTruncated)
        {
            yield return $"Showing the first {Format.Size(16 << 20)} of {Format.Size(body.Size)}.";
        }
    }

    /// <summary>The ways to view the body, side by side, as the Mac's segmented picker.</summary>
    private FrameworkElement ModePicker()
    {
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        var all = new List<ToggleButton>();
        foreach (var name in body.Modes)
        {
            var button = new ToggleButton
            {
                Content = Title(name, body),
                IsChecked = name == mode,
                Padding = new Thickness(10, 2, 10, 3),
                MinHeight = 0,
                MinWidth = 0,
                FontSize = 12,
            };
            button.Click += async (_, _) =>
            {
                mode = name;
                foreach (var other in all)
                {
                    other.IsChecked = other == button;
                }
                await ShowAsync();
            };
            all.Add(button);
            buttons.Children.Add(button);
        }
        return buttons;
    }

    // MARK: Protobuf

    /// <summary>The message type the body is read as, and the others to choose from, as the Mac's menu has them.</summary>
    private DropDownButton MessageTypeMenu(Settings.ProtobufModel protobuf)
    {
        var name = body.ProtobufType is { } type ? type[(type.LastIndexOf('.') + 1)..] : "No schema";
        var button = new DropDownButton { Content = name, FontSize = 12, Padding = new Thickness(10, 2, 8, 3), MinHeight = 0 };
        ToolTipService.SetToolTip(
            button, body.ProtobufType is { } read ? $"Read as {read}. Choose another message type." : "Fields show by number. Choose a message type.");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, "Message type");
        var menu = new MenuFlyout();
        menu.Opening += (_, _) => FillTypes(menu, protobuf);
        button.Flyout = menu;
        return button;
    }

    /// <summary>Automatic, then the types: in one list, or by package once there are more than 24; then where the types come from.</summary>
    private void FillTypes(MenuFlyout menu, Settings.ProtobufModel protobuf)
    {
        menu.Items.Clear();
        var automatic = new RadioMenuFlyoutItem { Text = "Automatic", GroupName = "MessageType", IsChecked = body.ChosenType is null };
        automatic.Click += (_, _) => _ = ChooseAsync(null);
        menu.Items.Add(automatic);
        var types = protobuf.Protobuf.Types;
        if (types.Length > 0)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
        }
        if (types.Length <= 24)
        {
            foreach (var type in types)
            {
                menu.Items.Add(TypeItem(type, type));
            }
        }
        else
        {
            foreach (var package in types.GroupBy(Package).OrderBy(group => group.Key.Length == 0 ? "\uFFFF" : group.Key, StringComparer.Ordinal))
            {
                var submenu = new MenuFlyoutSubItem { Text = package.Key.Length == 0 ? "No package" : package.Key };
                foreach (var type in package)
                {
                    submenu.Items.Add(TypeItem(type, type[(type.LastIndexOf('.') + 1)..]));
                }
                menu.Items.Add(submenu);
            }
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        var addFiles = new MenuFlyoutItem { Text = "Add .proto files…" };
        addFiles.Click += async (_, _) =>
        {
            await Settings.ProtobufSettingsView.AddFilesAsync(protobuf, context.WindowHandle);
            await ReloadAsync();
        };
        var addFolder = new MenuFlyoutItem { Text = "Add a folder of .proto files…" };
        addFolder.Click += async (_, _) =>
        {
            await Settings.ProtobufSettingsView.AddFolderAsync(protobuf, context.WindowHandle);
            await ReloadAsync();
        };
        var settings = new MenuFlyoutItem { Text = "Protobuf settings…" };
        settings.Click += (_, _) => App.Current.Main?.ShowSettings(Settings.SettingsWindow.Pane.Protobuf);
        menu.Items.Add(addFiles);
        menu.Items.Add(addFolder);
        menu.Items.Add(settings);
    }

    private RadioMenuFlyoutItem TypeItem(string type, string title)
    {
        var item = new RadioMenuFlyoutItem { Text = title, GroupName = "MessageType", IsChecked = body.ChosenType == type };
        item.Click += (_, _) => _ = ChooseAsync(type);
        return item;
    }

    /// <summary>A type's package, such as weather.v1, or none.</summary>
    private static string Package(string type) => type.LastIndexOf('.') is int dot and > 0 ? type[..dot] : "";

    /// <summary>Says why the fields show by number, and how to see their names.</summary>
    private StackPanel SchemaHint(Settings.ProtobufModel protobuf)
    {
        var line = new StackPanel { Spacing = 4 };
        line.Children.Add(Blocks.Note(body.HasMessageTypes
            ? "Fields show by number. Choose the body's message type to see their names."
            : "Fields show by number. Add the .proto files to see their names and types."));
        if (!body.HasMessageTypes)
        {
            line.Children.Add(Blocks.Link("Add .proto files…", async () =>
            {
                await Settings.ProtobufSettingsView.AddFilesAsync(protobuf, context.WindowHandle);
                await ReloadAsync();
            }));
        }
        return line;
    }

    /// <summary>Reads bodies like this one as a type from now on, or with none, as Reqly works out.</summary>
    private async Task ChooseAsync(string? type)
    {
        try
        {
            await Settings.ProtobufModel.ChooseAsync(context.Session, exchange, isRequest, type);
        }
        catch (CoreProblem problem)
        {
            AppLog.Write($"couldn't choose the message type: {problem.Message}");
            return;
        }
        await ReloadAsync();
    }

    /// <summary>Makes the body ready again and shows it in this one's place, as after its message type changed.</summary>
    private async Task ReloadAsync()
    {
        try
        {
            var request = new JsonObject { ["call"] = "presentBody", ["id"] = exchange, ["part"] = isRequest ? "request" : "response" };
            var fresh = Wire.Read<WireBody>(await context.Session.CallAsync(request));
            if (Parent is Panel panel && panel.Children.IndexOf(this) is int index and >= 0)
            {
                panel.Children[index] = new BodyView(context, exchange, isRequest, fresh, maxHeight, path);
            }
        }
        catch (CoreProblem problem)
        {
            AppLog.Write($"couldn't show the body again: {problem.Message}");
        }
    }

    private async Task ShowAsync()
    {
        switch (mode)
        {
            case "formatted" when body.Formatted is { } formatted:
                view.Content = new CodeView(formatted, maxHeight);
                break;
            case "raw" when body.Raw is { } raw:
                view.Content = new CodeView(raw, maxHeight);
                break;
            case "tree" when body.Tree is { } tree:
                view.Content = new TreeBodyView(tree, maxHeight, DescribeAsync, context.Copy);
                break;
            case "form":
                view.Content = Form(body.Fields ?? []);
                break;
            case "preview":
                view.Content = await PreviewAsync();
                break;
            default:
                var data = await BytesAsync();
                hex = new HexView(data, body.Size, maxHeight) { Copy = context.Copy };
                view.Content = hex;
                break;
        }
    }

    private async Task<byte[]> BytesAsync()
    {
        // The pane shows up to 16 MB of a body; more would be slow to lay out.
        bytes ??= await context.Session.BodyAsync(exchange, isRequest, 0, Math.Min(body.Size, 16 << 20), unpacked: true) ?? [];
        return bytes;
    }

    private async Task<(string Path, string Copy)?> DescribeAsync(int node)
    {
        try
        {
            var request = new JsonObject { ["call"] = "bodyNode", ["id"] = exchange, ["part"] = isRequest ? "request" : "response", ["node"] = node };
            var result = await context.Session.CallAsync(request);
            return (result.GetProperty("path").GetString() ?? "", result.GetProperty("copy").GetString() ?? "");
        }
        catch (CoreProblem)
        {
            return null;
        }
    }

    /// <summary>What Copy copies, as on the Mac: the formatted text, the raw text, the image, or the bytes as hex.</summary>
    private async Task CopyAsync()
    {
        switch (mode)
        {
            case "formatted" or "tree":
                context.Copy(body.Formatted?.Text ?? body.Raw?.Text ?? "");
                return;
            case "raw" or "form" when body.Raw is { } raw:
                context.Copy(raw.Text);
                return;
        }
        if (hex is not null)
        {
            context.Copy(hex.SelectedHex());
            return;
        }
        var data = await BytesAsync();
        context.Copy(string.Join(" ", data.Take(1 << 20).Select(value => value.ToString("X2"))));
    }

    private static FrameworkElement Form(WireFormField[] fields)
    {
        if (fields.Length == 0)
        {
            return Blocks.Note("This form has no fields.");
        }
        var rows = new StackPanel();
        foreach (var field in fields)
        {
            rows.Children.Add(Blocks.Row(field.Name, field.Value, monospaced: !field.IsFile));
        }
        return rows;
    }

    // MARK: Images

    private async Task<FrameworkElement> PreviewAsync()
    {
        var data = await BytesAsync();
        var panel = new StackPanel { Spacing = 8 };
        var frame = new Grid { Height = 300, CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), BorderBrush = Blocks.Resource("CardStrokeColorDefaultBrush") };
        frame.Children.Add(new Image { Source = Checkerboard(), Stretch = Stretch.UniformToFill });
        var image = new Image { Stretch = Stretch.Uniform, Margin = new Thickness(16) };
        frame.Children.Add(image);
        panel.Children.Add(frame);
        string? dimensions = null;
        var format = body.Kind;
        try
        {
            using var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
            {
                writer.WriteBytes(data);
                await writer.StoreAsync();
                await writer.FlushAsync();
            }
            if (body.Kind == "SVG")
            {
                var svg = new SvgImageSource();
                await svg.SetSourceAsync(stream);
                image.Source = svg;
            }
            else
            {
                var decoder = await BitmapDecoder.CreateAsync(stream);
                dimensions = $"{decoder.OrientedPixelWidth:N0} × {decoder.OrientedPixelHeight:N0} pixels";
                if (decoder.BitmapAlphaMode != BitmapAlphaMode.Ignore && body.Kind is "PNG" or "WebP" or "GIF" or "ICO" or "TIFF" or "HEIC" or "AVIF")
                {
                    format += ", with transparency";
                }
                stream.Seek(0);
                var bitmap = new BitmapImage();
                await bitmap.SetSourceAsync(stream);
                image.Source = bitmap;
                // Never larger than its own pixels.
                image.MaxWidth = decoder.OrientedPixelWidth;
                image.MaxHeight = decoder.OrientedPixelHeight;
            }
        }
        catch (Exception)
        {
            frame.Children.Add(new TextBlock { Text = "Reqly can't show this image.", HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Foreground = Blocks.Resource("TextFillColorSecondaryBrush") });
        }
        panel.Children.Add(Blocks.Row("Format", format));
        if (dimensions is not null)
        {
            panel.Children.Add(Blocks.Row("Dimensions", dimensions));
        }
        panel.Children.Add(Blocks.Row("Size", Format.Size(data.Length)));
        var open = new Button { Content = "Open", FontSize = 12, Padding = new Thickness(10, 3, 10, 4), MinHeight = 0 };
        ToolTipService.SetToolTip(open, "Open the image in the app Windows opens images with");
        open.Click += async (_, _) => await OpenImageAsync(data);
        var save = new Button { Content = "Save image…", FontSize = 12, Padding = new Thickness(10, 3, 10, 4), MinHeight = 0 };
        save.Click += async (_, _) => await SaveImageAsync(data);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        buttons.Children.Add(open);
        buttons.Children.Add(save);
        panel.Children.Add(buttons);
        return panel;
    }

    /// <summary>The image's file name: the URL's, when it has an extension, or image.png and the like.</summary>
    private string ImageFileName()
    {
        var last = Uri.UnescapeDataString(path?.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "");
        foreach (var invalid in System.IO.Path.GetInvalidFileNameChars())
        {
            last = last.Replace(invalid, '-');
        }
        return last.Contains('.') ? last : $"image.{body.Kind.ToLowerInvariant()}";
    }

    /// <summary>Opens the image in the app Windows opens its kind with, from a copy in Reqly's temporary folder.</summary>
    private async Task OpenImageAsync(byte[] data)
    {
        try
        {
            var folder = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "Reqly Images");
            Directory.CreateDirectory(folder);
            var file = System.IO.Path.Combine(folder, ImageFileName());
            await File.WriteAllBytesAsync(file, data);
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(file) { UseShellExecute = true });
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            AppLog.Write($"couldn't open the image: {error.Message}");
        }
    }

    private async Task SaveImageAsync(byte[] data)
    {
        var name = ImageFileName();
        var picker = new Windows.Storage.Pickers.FileSavePicker
        {
            SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.PicturesLibrary,
            SuggestedFileName = System.IO.Path.GetFileNameWithoutExtension(name),
        };
        picker.FileTypeChoices.Add($"{body.Kind} image", [System.IO.Path.GetExtension(name)]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, context.WindowHandle());
        if (await picker.PickSaveFileAsync() is not { } chosen)
        {
            return;
        }
        try
        {
            await File.WriteAllBytesAsync(chosen.Path, data);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            AppLog.Write($"couldn't save the image: {error.Message}");
        }
    }

    private static ImageSource Checkerboard()
    {
        // Light and dark squares, ten pixels each, behind images with transparency.
        const int Width = 800, Height = 300, Square = 10;
        var isDark = ((SolidColorBrush)Palette.CodeBackground).Color.R < 0x80;
        var (first, second) = isDark ? ((byte)0x2B, (byte)0x36) : ((byte)0xFF, (byte)0xEE);
        var bitmap = new WriteableBitmap(Width, Height);
        var pixels = new byte[Width * Height * 4];
        for (var y = 0; y < Height; y++)
        {
            for (var x = 0; x < Width; x++)
            {
                var value = ((x / Square) + (y / Square)) % 2 == 0 ? first : second;
                var at = (y * Width + x) * 4;
                pixels[at] = value;
                pixels[at + 1] = value;
                pixels[at + 2] = value;
                pixels[at + 3] = 255;
            }
        }
        using (var stream = bitmap.PixelBuffer.AsStream())
        {
            stream.Write(pixels, 0, pixels.Length);
        }
        bitmap.Invalidate();
        return bitmap;
    }
}
