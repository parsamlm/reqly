using Reqly.Core;
using Reqly.Settings;

namespace Reqly;

/// <summary>Reqly's own connections: the upstream proxy, the reverse proxies and the client certificates, as on the Mac.</summary>
public sealed partial class MainWindow
{
    private ConnectionsModel? connections;
    private ProtobufModel? protobuf;

    public ConnectionsModel? Connections => connections;

    /// <summary>The .proto files every window's bodies are read with.</summary>
    public ProtobufModel? Protobuf => protobuf;

    private async Task OpenProtobufAsync(CoreSession session)
    {
        protobuf = new ProtobufModel(session);
        await protobuf.OpenAsync(options.ProtobufFile);
        Log($"protobuf: {protobuf.Protobuf.Sources.Length} sources · {protobuf.Protobuf.Summary}");
    }

    private async Task OpenConnectionsAsync(CoreSession session)
    {
        connections = new ConnectionsModel(session, () => Port);
        connections.Changed += ShowStatus;
        await connections.OpenAsync(options.ConnectionsFile, options.SecretsStandIn ?? options.SecretsFile, protectsSecrets: options.SecretsStandIn is null);
        var shown = connections.Connections;
        var problem = shown.Problem is { } text ? $" · {text}" : "";
        Log($"connections: upstream {shown.ActiveUpstreamProxy ?? "none"}, {shown.ReverseProxies.Length} reverse proxies, {shown.ClientCertificates.Length} client certificates{problem}");
    }

    /// <summary>What the status bar adds while capturing: the upstream proxy traffic goes through, and the reverse proxies listening.</summary>
    private string ConnectionsNote()
    {
        if (connections?.Connections is not { } shown)
        {
            return "";
        }
        var network = devices?.Devices is { AllowsNetworkDevices: true, Problem: null } ? " · Devices can connect" : "";
        var via = shown.ActiveUpstreamProxy is { } address ? $" · Via {address}" : "";
        var listening = shown.ReverseProxies.Count(proxy => proxy.IsOn && proxy.Problem is null);
        var reverse = listening switch { 0 => "", 1 => " · 1 reverse proxy", _ => $" · {listening} reverse proxies" };
        return network + via + reverse;
    }

    /// <summary>The status bar's tooltip while capturing: where traffic goes, in sentences.</summary>
    private string? ConnectionsTip()
    {
        if (connections?.Connections is not { } shown)
        {
            return null;
        }
        var lines = new List<string>();
        if (shown.ActiveUpstreamProxy is { } address)
        {
            lines.Add($"Traffic goes through the upstream proxy at {address}.");
        }
        foreach (var proxy in shown.ReverseProxies.Where(proxy => proxy.IsOn && proxy.Problem is null))
        {
            lines.Add($"A reverse proxy on {proxy.LocalAddress} sends requests to {proxy.Server}.");
        }
        return lines.Count == 0 ? null : string.Join("\n", lines);
    }
}
