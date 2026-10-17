using System.Text.Json;
using System.Text.Json.Nodes;
using Reqly.Core;

namespace Reqly.Settings;

/// <summary>
/// How Reqly's own connections go, as Settings edit them: through an upstream proxy, from reverse
/// proxies, and with client certificates. The core keeps them in the same file the Mac keeps them
/// in, with the proxy's password and the certificates' keys encrypted for your Windows account.
/// </summary>
public sealed class ConnectionsModel(CoreSession session, Func<int> proxyPort)
{
    public WireConnections Connections { get; private set; } = WireConnections.None;

    /// <summary>The settings changed, or why reverse proxies aren't listening did.</summary>
    public event Action? Changed;

    /// <summary>The port Reqly's proxy listens on, which the other proxies can't use.</summary>
    public int ProxyPort => proxyPort();

    public async Task OpenAsync(string file, string secretsFile, bool protectsSecrets)
    {
        await ChangeAsync(new JsonObject
        {
            ["call"] = "openConnections",
            ["path"] = file,
            ["secretsPath"] = secretsFile,
            ["protectsSecrets"] = protectsSecrets,
        });
    }

    /// <summary>Reads the settings again, with why reverse proxies aren't listening, as after capturing starts or stops.</summary>
    public Task RefreshAsync() => ChangeAsync(new JsonObject { ["call"] = "connections" });

    // MARK: The upstream proxy

    public async Task<string?> CheckUpstreamProxyAsync(WireUpstreamProxy proxy)
    {
        var result = await session.CallAsync(new JsonObject { ["call"] = "checkUpstreamProxy", ["proxy"] = Node(proxy), ["proxyPort"] = ProxyPort });
        return Text(result, "problem");
    }

    /// <summary>Applies the upstream proxy, or says what to fix.</summary>
    public Task<string?> SetUpstreamProxyAsync(WireUpstreamProxy proxy) =>
        ChangeOrProblemAsync(new JsonObject { ["call"] = "setUpstreamProxy", ["proxy"] = Node(proxy), ["proxyPort"] = ProxyPort });

    // MARK: Reverse proxies

    /// <summary>A new reverse proxy to edit, on a port none uses yet.</summary>
    public async Task<WireReverseProxy> NewReverseProxyAsync() =>
        Wire.Read<WireReverseProxy>(await session.CallAsync(new JsonObject { ["call"] = "newReverseProxy", ["proxyPort"] = ProxyPort }));

    public async Task<WireCheck> CheckReverseProxyAsync(WireReverseProxy proxy) =>
        Wire.Read<WireCheck>(await session.CallAsync(new JsonObject { ["call"] = "checkReverseProxy", ["proxy"] = Node(proxy), ["proxyPort"] = ProxyPort }));

    public Task<string?> SaveReverseProxyAsync(WireReverseProxy proxy) =>
        ChangeOrProblemAsync(new JsonObject { ["call"] = "saveReverseProxy", ["proxy"] = Node(proxy), ["proxyPort"] = ProxyPort });

    public Task RemoveReverseProxyAsync(Guid id) =>
        ChangeAsync(new JsonObject { ["call"] = "removeReverseProxy", ["reverseProxy"] = id.ToString() });

    public Task SetReverseProxyOnAsync(Guid id, bool isOn) =>
        ChangeAsync(new JsonObject { ["call"] = "setReverseProxyOn", ["reverseProxy"] = id.ToString(), ["isOn"] = isOn });

    /// <summary>The reverse proxy as its editor starts: as it's saved.</summary>
    public static WireReverseProxy Edit(WireReverseProxyRow row) => new()
    {
        Id = row.Id,
        IsOn = row.IsOn,
        Port = row.LocalPort.ToString(System.Globalization.CultureInfo.InvariantCulture),
        ServerURL = row.ServerURL,
        RewritesRedirects = row.RewritesRedirects,
    };

    // MARK: Client certificates

    public async Task<WireHostsCheck> CheckHostsAsync(string text) =>
        Wire.Read<WireHostsCheck>(await session.CallAsync(new JsonObject { ["call"] = "checkHosts", ["text"] = text }));

    /// <summary>Reads a certificate and its key from files, and presents them to the hosts from now on; or says what's wrong.</summary>
    public Task<string?> AddClientCertificateAsync(IEnumerable<string> files, string password, string hosts) =>
        ChangeOrProblemAsync(new JsonObject
        {
            ["call"] = "addClientCertificate",
            ["files"] = new JsonArray(files.Select(file => (JsonNode)JsonValue.Create(file)!).ToArray()),
            ["password"] = password,
            ["hosts"] = hosts,
        });

    public Task<string?> SetClientCertificateHostsAsync(Guid id, string hosts) =>
        ChangeOrProblemAsync(new JsonObject { ["call"] = "setClientCertificateHosts", ["certificate"] = id.ToString(), ["hosts"] = hosts });

    public Task SetClientCertificateOnAsync(Guid id, bool isOn) =>
        ChangeAsync(new JsonObject { ["call"] = "setClientCertificateOn", ["certificate"] = id.ToString(), ["isOn"] = isOn });

    public Task RemoveClientCertificateAsync(Guid id) =>
        ChangeAsync(new JsonObject { ["call"] = "removeClientCertificate", ["certificate"] = id.ToString() });

    // MARK: -

    private static JsonNode? Node<T>(T value) => JsonSerializer.SerializeToNode(value, Wire.Options);

    private static string? Text(JsonElement result, string name) =>
        result.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private async Task ChangeAsync(JsonObject call)
    {
        try
        {
            Connections = Wire.Read<WireConnections>(await session.CallAsync(call));
        }
        catch (CoreProblem problem)
        {
            AppLog.Write($"couldn't change the connections ({call["call"]}): {problem.Message}");
            return;
        }
        Changed?.Invoke();
    }

    private async Task<string?> ChangeOrProblemAsync(JsonObject call)
    {
        try
        {
            Connections = Wire.Read<WireConnections>(await session.CallAsync(call));
        }
        catch (CoreProblem problem)
        {
            return problem.Message;
        }
        Changed?.Invoke();
        return null;
    }
}
