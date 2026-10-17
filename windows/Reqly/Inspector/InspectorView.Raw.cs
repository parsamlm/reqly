using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Reqly.Core;

namespace Reqly.Inspector;

/// <summary>The Raw tab, as the Mac's: the request and the response as text, the way HTTP/1.1 writes them.</summary>
public sealed partial class InspectorView
{
    /// <summary>Whether the Raw tab shows secrets such as cookies, until another request is shown.</summary>
    private bool rawShowsSecrets;
    private ulong? rawSecretsFor;

    private async Task<List<UIElement>> RawTabAsync(WireDetails shown)
    {
        var parts = new List<UIElement>();
        if (context is null)
        {
            return parts;
        }
        if (rawSecretsFor != shown.Id)
        {
            rawSecretsFor = shown.Id;
            rawShowsSecrets = false;
        }
        WireRaw raw;
        try
        {
            raw = Wire.Read<WireRaw>(await context.Session.CallAsync(new JsonObject { ["call"] = "raw", ["id"] = shown.Id, ["showsSecrets"] = rawShowsSecrets }));
        }
        catch (CoreProblem problem)
        {
            parts.Add(Blocks.Note(problem.Message));
            return parts;
        }
        if (raw.HasSecrets)
        {
            var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            line.Children.Add(Blocks.Note(rawShowsSecrets
                ? "Cookies and authorization headers are showing."
                : "Cookies and authorization headers are hidden."));
            line.Children.Add(Blocks.Link(rawShowsSecrets ? "Hide them" : "Show them", () =>
            {
                rawShowsSecrets = !rawShowsSecrets;
                _ = ShowTabAsync(keepsScroll: true);
            }));
            parts.Add(line);
        }
        parts.Add(RawSection("Request", raw.Request));
        if (raw.Response is { } response)
        {
            parts.Add(RawSection("Response", response));
        }
        else
        {
            var section = Blocks.Section("Response");
            section.Children.Add(Blocks.Note(shown.IsTunnel ? "Reqly doesn't decrypt this host." : "No response yet."));
            parts.Add(section);
        }
        if (shown.Version == "HTTP/2")
        {
            parts.Add(Blocks.Note("HTTP/2 sends these as binary frames. Reqly writes them the way HTTP/1.1 does, so they're easy to read."));
        }
        return parts;
    }

    private StackPanel RawSection(string title, WireCode code)
    {
        // What's copied is what shows, dots and notes included.
        var copy = Blocks.IconButton("\uE8C8", $"Copy raw {title.ToLowerInvariant()}", () => context?.Copy(code.Text));
        var section = Blocks.Section(title, accessory: copy);
        section.Children.Add(new CodeView(code, ViewerHeight));
        return section;
    }
}
