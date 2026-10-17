using System.Text.Json.Nodes;
using Reqly.Core;

namespace Reqly.Settings;

/// <summary>
/// The .proto files protobuf and gRPC bodies are read with, and the message types chosen for
/// bodies that don't say theirs. Every window's bodies use them; the core keeps them in the same
/// file the Mac keeps them in, and reads the files again each time Reqly opens.
/// </summary>
public sealed class ProtobufModel(CoreSession session)
{
    public WireProtobuf Protobuf { get; private set; } = WireProtobuf.None;

    /// <summary>Whether the files are being read.</summary>
    public bool IsLoading { get; private set; }

    /// <summary>The list changed, or the files were read again.</summary>
    public event Action? Changed;

    public Task OpenAsync(string file) => ChangeAsync(new JsonObject { ["call"] = "openProtobuf", ["path"] = file });

    public Task AddAsync(IEnumerable<string> paths) =>
        ChangeAsync(new JsonObject { ["call"] = "addProtobufSources", ["paths"] = new JsonArray(paths.Select(path => (JsonNode)JsonValue.Create(path)!).ToArray()) });

    public Task RemoveAsync(string path) => ChangeAsync(new JsonObject { ["call"] = "removeProtobufSource", ["path"] = path });

    /// <summary>Reads the files again, after you change them.</summary>
    public Task ReloadAsync() => ChangeAsync(new JsonObject { ["call"] = "reloadProtobuf" });

    /// <summary>
    /// Reads bodies like this one, the same part of requests to the same host and path, as a message
    /// type from now on, or with none, as Reqly works out. The exchange is in the session it's from.
    /// </summary>
    public static async Task ChooseAsync(CoreSession session, ulong exchange, bool isRequest, string? type)
    {
        var call = new JsonObject { ["call"] = "chooseMessageType", ["id"] = exchange, ["part"] = isRequest ? "request" : "response" };
        if (type is not null)
        {
            call["type"] = type;
        }
        await session.CallAsync(call);
    }

    private async Task ChangeAsync(JsonObject call)
    {
        IsLoading = true;
        Changed?.Invoke();
        try
        {
            Protobuf = Wire.Read<WireProtobuf>(await session.CallAsync(call));
        }
        catch (CoreProblem problem)
        {
            AppLog.Write($"couldn't change the .proto files ({call["call"]}): {problem.Message}");
        }
        IsLoading = false;
        Changed?.Invoke();
    }
}
