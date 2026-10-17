namespace Reqly.Rules;

/// <summary>The kinds of rule, as the Rules window, the menus and the details name them.</summary>
public static class RuleKinds
{
    /// <summary>
    /// A kind of rule: its name, the name of one rule of it, such as "New Map Local rule", the Add
    /// rule menu's item, its icon, and what the Rules window says about it.
    /// </summary>
    public sealed record Kind(string Id, string Title, string RuleTitle, string MenuTitle, string Glyph, string Explanation, string OrderNote);

    private const string FirstActs = "When several rules match a request, the first one in the list acts.";

    public static readonly Kind[] All =
    [
        new("breakpoint", "Breakpoints", "breakpoint", "Breakpoint…", "",
            "Pause matching traffic so you can edit it before it continues. You can also turn this on from the toolbar.", FirstActs),
        new("mapLocal", "Map Local", "Map Local rule", "Map Local…", "",
            "Answer matching requests with a file on your PC. The server never sees them.",
            "When several rules match a request, the first one in the list acts. Block rules act before Map Local."),
        new("mapRemote", "Map Remote", "Map Remote rule", "Map Remote…", "",
            "Send matching requests to another server, such as staging instead of production.", FirstActs),
        new("rewrite", "Rewrite", "Rewrite rule", "Rewrite…", "",
            "Change the headers, query, body text or status of matching traffic as it passes.",
            "Every rule that matches makes its changes, in the order of the list."),
        new("block", "Block", "Block rule", "Block…", "",
            "Stop matching requests, with a status of your choice or by closing the connection.", FirstActs),
        new("script", "Scripts", "script", "Script…", "",
            "Run JavaScript on matching traffic, to change requests and responses as they pass, or to answer requests yourself.",
            "Every script that matches runs, in the order of the list, after Rewrite rules and before breakpoints."),
        new("slowNetwork", "Slow Network", "Slow Network", "Slow Network…", "",
            "Slow traffic down to the speed of a slower network, to see how apps cope.", ""),
    ];

    /// <summary>The kinds that are rules of their own, as Add rule offers them.</summary>
    public static IEnumerable<Kind> Rules => All.Where(kind => kind.Id != "slowNetwork");

    public static Kind Of(string id) => All.FirstOrDefault(kind => kind.Id == id) ?? new(id, id, id, id, "", "", "");
}
