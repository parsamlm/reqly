using System.Text.Json;
using System.Text.Json.Nodes;
using Reqly.Core;

namespace Reqly.Rules;

/// <summary>
/// The rules that change traffic, as the Rules window edits them. The core keeps them in their
/// file, the same JSON the Mac keeps, and each change applies to the requests that start after it.
/// </summary>
public sealed class RulesModel(CoreSession session)
{
    public WireRules Rules { get; private set; } = WireRules.None;
    /// <summary>Slow Network's profiles to choose from.</summary>
    public WireNetworkProfile[] Presets { get; private set; } = [];
    /// <summary>Scripts to start from, for the script editor's Examples menu.</summary>
    public WireScriptExample[] Examples { get; private set; } = [];

    public CoreSession Session => session;

    /// <summary>The rules changed, here or in the Rules window.</summary>
    public event Action? Changed;

    /// <summary>Opens the rules file, which gives the session its rules.</summary>
    public async Task OpenAsync(string file)
    {
        try
        {
            Presets = Wire.Read<WireNetworkProfile[]>(await session.CallAsync(new JsonObject { ["call"] = "networkPresets" }));
            Examples = Wire.Read<WireScriptExample[]>(await session.CallAsync(new JsonObject { ["call"] = "scriptExamples" }));
        }
        catch (CoreProblem problem)
        {
            AppLog.Write($"couldn't read the presets and examples: {problem.Message}");
        }
        await ChangeAsync(new JsonObject { ["call"] = "openRules", ["path"] = file });
    }

    /// <summary>Reads the rules again, after a change made around this model, such as by the self-check.</summary>
    public Task RefreshAsync() => ChangeAsync(new JsonObject { ["call"] = "rules" });

    public bool IsOn(string kind) => Rules.KindsOn.Contains(kind);

    /// <summary>The rules of one kind, in the order they act.</summary>
    public WireRuleRow[] Of(string kind) => [.. Rules.Rules.Where(rule => rule.Kind == kind)];

    public Task SetOnAsync(string kind, bool isOn) =>
        ChangeAsync(new JsonObject { ["call"] = "setRuleKindOn", ["kind"] = kind, ["isOn"] = isOn });

    public Task SetRuleOnAsync(Guid id, bool isOn) =>
        ChangeAsync(new JsonObject { ["call"] = "setRuleOn", ["rule"] = id.ToString(), ["isOn"] = isOn });

    public Task RemoveAsync(Guid id) =>
        ChangeAsync(new JsonObject { ["call"] = "removeRules", ["ruleIDs"] = new JsonArray(id.ToString()) });

    /// <summary>Moves a rule to another place among the rules of its kind. The first rule that matches a request acts.</summary>
    public Task MoveAsync(Guid id, int place) =>
        ChangeAsync(new JsonObject { ["call"] = "moveRule", ["rule"] = id.ToString(), ["to"] = place });

    /// <summary>Adds a copy of a rule, last among the rules of its kind.</summary>
    public Task DuplicateAsync(Guid id) =>
        ChangeAsync(new JsonObject { ["call"] = "duplicateRule", ["rule"] = id.ToString() });

    public Task SetNetworkAsync(WireNetwork network) =>
        ChangeAsync(new JsonObject { ["call"] = "setNetwork", ["network"] = JsonSerializer.SerializeToNode(network, Wire.Options) });

    /// <summary>A new rule to edit, filled in from a request of a session when there is one, such as a saved session's.</summary>
    public static async Task<WireRuleDraft> NewDraftAsync(CoreSession session, string kind, ulong? exchange)
    {
        var call = new JsonObject { ["call"] = "newRuleDraft", ["kind"] = kind };
        if (exchange is ulong id)
        {
            call["id"] = id;
        }
        return Wire.Read<WireRuleDraft>(await session.CallAsync(call));
    }

    public Task<WireRuleDraft> NewDraftAsync(string kind) => NewDraftAsync(session, kind, null);

    /// <summary>A saved rule, to edit.</summary>
    public async Task<WireRuleDraft> DraftAsync(Guid id) =>
        Wire.Read<WireRuleDraft>(await session.CallAsync(new JsonObject { ["call"] = "ruleDraft", ["rule"] = id.ToString() }));

    /// <summary>What to fix in a draft, the name it gets, and how many requests captured so far it matches.</summary>
    public async Task<WireRuleCheck> CheckAsync(WireRuleDraft draft) =>
        Wire.Read<WireRuleCheck>(await session.CallAsync(new JsonObject { ["call"] = "checkRuleDraft", ["draft"] = Node(draft) }));

    /// <summary>Saves a draft's rule, or says what to fix. A new rule's kind comes on with it, so the rule acts.</summary>
    public async Task<string?> SaveAsync(WireRuleDraft draft)
    {
        try
        {
            Rules = Wire.Read<WireRules>(await session.CallAsync(new JsonObject { ["call"] = "saveRuleDraft", ["draft"] = Node(draft) }));
        }
        catch (CoreProblem problem)
        {
            return problem.Message;
        }
        Changed?.Invoke();
        return null;
    }

    /// <summary>What's wrong with a script, with its line, or nothing when it reads.</summary>
    public async Task<string?> CheckScriptAsync(string code)
    {
        var result = await session.CallAsync(new JsonObject { ["call"] = "checkScript", ["code"] = code });
        return result.TryGetProperty("problem", out var problem) && problem.ValueKind == JsonValueKind.String ? problem.GetString() : null;
    }

    /// <summary>A script's keywords, strings, numbers, literals and comments, to color them, as the core reads them.</summary>
    public async Task<JsonElement[][]> HighlightScriptAsync(string code)
    {
        var result = await session.CallAsync(new JsonObject { ["call"] = "highlightScript", ["code"] = code });
        return Wire.Read<JsonElement[][]>(result.GetProperty("tokens"));
    }

    /// <summary>What a script would do to a request captured earlier, and to its response. Nothing is sent.</summary>
    public async Task<WireScriptTrial[]> TryScriptAsync(string code, ulong id)
    {
        var result = await session.CallAsync(new JsonObject { ["call"] = "tryScript", ["code"] = code, ["id"] = id });
        return Wire.Read<WireScriptTrial[]>(result.GetProperty("trials"));
    }

    private static JsonNode? Node(WireRuleDraft draft) => JsonSerializer.SerializeToNode(draft, Wire.Options);

    private async Task ChangeAsync(JsonObject call)
    {
        try
        {
            Rules = Wire.Read<WireRules>(await session.CallAsync(call));
        }
        catch (CoreProblem problem)
        {
            AppLog.Write($"couldn't change the rules ({call["call"]}): {problem.Message}");
            return;
        }
        Changed?.Invoke();
    }
}
