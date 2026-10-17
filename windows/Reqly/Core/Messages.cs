using System.Text.Json;

namespace Reqly.Core;

/// <summary>
/// What the core's replies carry, as CoreInterface's Messages.swift sends it. Names match the
/// JSON; times are seconds since 1970.
/// </summary>
public sealed record WireRow(
    ulong Id, string Kind, string Method, string Scheme, string Host, int Port, string Target, int? Status,
    string State, double Started, double? Duration, long BytesSent, long BytesReceived, string? ContentType,
    string? App, string? AppPath, string? Device, bool IsPinned, string? Color, string? Comment, int MessageCount,
    int? GrpcStatus, string? StatusClass, string? GrpcTitle);

/// <summary>Every exchange in a session at a glance, whatever the list shows: how many, what they sent and received, and the newest.</summary>
public sealed record WireTrafficSummary(int Total, long Bytes, WireRow? Newest);

/// <summary>A header, or a query's name and value. Secrets, such as cookies, show as dots until you choose to see them.</summary>
public sealed record WireHeader(string Name, string Value, bool IsSecret = false);

/// <summary>An exchange's details, as CoreInterface's WireDetails sends them. Bodies come separately.</summary>
public sealed class WireDetails
{
    public ulong Id { get; init; }
    /// <summary>http, or tunnel for an encrypted connection that passes through.</summary>
    public string Kind { get; init; } = "http";
    public string Method { get; init; } = "";
    /// <summary>The full URL, when one can be formed.</summary>
    public string? Url { get; init; }
    public string Scheme { get; init; } = "";
    public string Host { get; init; } = "";
    public int Port { get; init; }
    public string Target { get; init; } = "";
    /// <summary>The target without its query.</summary>
    public string Path { get; init; } = "";
    public WireHeader[] Query { get; init; } = [];
    public string Version { get; init; } = "";
    public WireHeader[] RequestHeaders { get; init; } = [];
    public int RequestBodySize { get; init; }
    public int? Status { get; init; }
    public string? Reason { get; init; }
    public string? ResponseVersion { get; init; }
    public WireHeader[]? ResponseHeaders { get; init; }
    public int ResponseBodySize { get; init; }
    public string State { get; init; } = "";
    public string? Failure { get; init; }
    public double Started { get; init; }
    public double? Ended { get; init; }
    public string? RemoteAddress { get; init; }
    public string? TlsVersion { get; init; }
    public string? ServerProtocol { get; init; }
    public bool ReusedConnection { get; init; }
    public string? UpstreamProxy { get; init; }
    public string? ReverseProxy { get; init; }
    public string? ClientCertificate { get; init; }
    public bool SentByReqly { get; init; }
    /// <summary>plain, encryptedTunnel, decrypted or certificateRejected.</summary>
    public string Decryption { get; init; } = "plain";
    public string? App { get; init; }
    public string? Device { get; init; }
    public bool IsPinned { get; init; }
    public string? Color { get; init; }
    public string? Comment { get; init; }
    public long BytesSent { get; init; }
    public long BytesReceived { get; init; }
    public bool IsWebSocket { get; init; }
    public int MessageCount { get; init; }
    public WireGrpc? Grpc { get; init; }
    public WireHeader[]? ResponseTrailers { get; init; }
    public WirePhase[] Phases { get; init; } = [];
    public double? ConnectStarted { get; init; }
    public WireRule[] AppliedRules { get; init; } = [];
    public WireScriptOutput[] ScriptOutput { get; init; } = [];
    public WireSource? Source { get; init; }
    public WireDeviceInfo? DeviceInfo { get; init; }
    /// <summary>request or response, while a breakpoint holds the exchange.</summary>
    public string? PausedPart { get; init; }
    public WireCookie[] RequestCookies { get; init; } = [];
    public WireCookie[] ResponseCookies { get; init; } = [];

    public bool IsTunnel => Kind == "tunnel";
}

public sealed record WireGrpc(int Code, string Name, string Title, string? Message);

/// <summary>A step of the exchange: queued, dnsLookup, connecting, tlsHandshake, requestSent, waiting, downloading or open.</summary>
public sealed record WirePhase(string Step, double Start, double End);

public sealed record WireRule(string Kind, string Name, string Detail);

public sealed record WireScriptOutput(string Rule, string Part, string[] Lines);

public sealed record WireDeviceInfo(string Id, string Name, string Kind, string? Address, string FullName);

public sealed record WireCookie(string Name, string Value, double? Expires, string? ExpiresText, string[] Attributes);

/// <summary>Text with its syntax marked: each token is [location, length, kind], in UTF-16 code units, as C# counts them.</summary>
public sealed class WireCode
{
    public string Text { get; init; } = "";
    public JsonElement[][] Tokens { get; init; } = [];
    /// <summary>Code keeps whole lines and scrolls sideways; text wraps.</summary>
    public bool IsCode { get; init; }
}

public sealed record WireTreeNode(string Label, string Summary, string Type, string Style, int? Parent, int[] Children, int Depth);

public sealed record WireTree(WireTreeNode[] Nodes);

public sealed record WireFormField(string Name, string Value, bool IsFile);

/// <summary>A body made ready to show: what it is, the ways to view it, and what each one shows.</summary>
public sealed class WireBody
{
    /// <summary>Such as JSON or PNG.</summary>
    public string Kind { get; init; } = "";
    /// <summary>formatted, tree, raw, preview, form or hex, the best first.</summary>
    public string[] Modes { get; init; } = [];
    public string? Note { get; init; }
    public WireCode? Formatted { get; init; }
    public WireCode? Raw { get; init; }
    public WireTree? Tree { get; init; }
    public bool TreeIsTooBig { get; init; }
    public WireFormField[]? Fields { get; init; }
    public bool IsImage { get; init; }
    public int WireSize { get; init; }
    public int Size { get; init; }
    public string? UnpackedFrom { get; init; }
    public bool IsTruncated { get; init; }
    public bool ReadsAsProtobuf { get; init; }
    public int? MessageCount { get; init; }
    public string? ProtobufType { get; init; }
    /// <summary>The message type chosen for bodies like this one, if one was.</summary>
    public string? ChosenType { get; init; }
    /// <summary>Whether the .proto files have message types to choose from.</summary>
    public bool HasMessageTypes { get; init; }
    public WireGrpc? Grpc { get; init; }
    public string[] Details { get; init; } = [];
}

public sealed class WireRaw
{
    public WireCode Request { get; init; } = new();
    public WireCode? Response { get; init; }
    public bool HasSecrets { get; init; }
}

/// <summary>A WebSocket message, as the Messages tab lists it.</summary>
public sealed record WireMessage(
    int Number, string Direction, string Kind, double Time, int Size, int KeptSize, int? CloseCode, string? Text,
    string Preview);

/// <summary>A host to decrypt, such as api.example.com or *.example.com, switched on or off.</summary>
public sealed record WireHostEntry(string Pattern, bool IsOn);

/// <summary>The hosts to decrypt, and whether every other host is decrypted too.</summary>
public sealed record WireHosts(WireHostEntry[] Entries, bool IncludesEveryHost)
{
    public static readonly WireHosts None = new([], false);
}

/// <summary>
/// Whether Reqly's certificate is set up and trusted ("notSetUp", "notTrusted" or "trusted"), and
/// the hosts to decrypt. The certificate, in base64, is there only while Windows trusts it.
/// </summary>
public sealed record WireHttps(
    string Status, string? CertificateName, double? Created, string? Certificate, WireHosts Hosts);

/// <summary>An app or tool that sent traffic, as the core names it.</summary>
public sealed record WireSource(string Name, string? BundleID, string? Path);

/// <summary>A row of the sidebar: its key, which narrows the list to it, its name and its count.</summary>
public sealed record WireSidebarRow(string Key, string Name, int Count, string? Path);

/// <summary>This computer (no name), or a device, with its apps and the hosts of its other traffic.</summary>
public sealed record WireDeviceRow(
    string Key, string Id, string? Name, string? Kind, int Count, WireSidebarRow[] Apps, WireSidebarRow[] OtherHosts);

/// <summary>The sidebar, as the core's "sidebar" event sends it when rows come or go.</summary>
public sealed record WireSidebar(
    int Total, int Pinned, WireSidebarRow[] Apps, WireSidebarRow[] Hosts, WireDeviceRow[] Devices, string[] Methods,
    WireSource[] Sources);

/// <summary>A request as you write it in the composer.</summary>
public sealed class WireOutgoing
{
    public string Method { get; set; } = "GET";
    public string Url { get; set; } = "https://";
    public List<WireOutgoingHeader> Headers { get; set; } = [];
    public string? Body { get; set; }
    /// <summary>A body that isn't text, in base64. It's sent as it was, unless you remove it.</summary>
    public string? BinaryBody { get; set; }
}

public sealed class WireOutgoingHeader
{
    public string Name { get; set; } = "";
    public string Value { get; set; } = "";
    /// <summary>Whether to send it. Turning a header off keeps it for later.</summary>
    public bool IsOn { get; set; } = true;
}

/// <summary>A request or a response held at a breakpoint, ready to edit.</summary>
public sealed record WirePaused(
    ulong Id, string Part, string Breakpoint, string Method, string Url, string Status, string Reason, WireHeader[] Headers,
    string Body, int? BinaryBodySize);

/// <summary>The rules, as the Rules window lists them, and why they can't be read or saved, if they can't.</summary>
public sealed record WireRules(string[] KindsOn, WireRuleRow[] Rules, WireNetwork Network, string? Problem)
{
    public static readonly WireRules None = new([], [], new WireNetwork(new WireNetworkProfile("3G", 97_500, 41_250, 100, 0), []), null);
}

/// <summary>A rule in the list: what it matches, such as "GET · api.weatherly.dev/v2/*", and in a word or two what it does.</summary>
public sealed record WireRuleRow(Guid Id, string Kind, string Name, bool IsOn, string Match, string Tag);

/// <summary>What Slow Network slows down: every host, with none listed.</summary>
public sealed record WireNetwork(WireNetworkProfile Profile, string[] Hosts);

/// <summary>A network to slow traffic down to. Speeds are bytes a second, and none is no limit; latency is milliseconds.</summary>
public sealed record WireNetworkProfile(string Name, long? DownloadBytesPerSecond, long? UploadBytesPerSecond, int Latency, double PacketLoss);

/// <summary>A rule as the editor edits it, field for field as the core's RuleDraft.</summary>
public sealed class WireRuleDraft
{
    public Guid Id { get; set; }
    public bool IsNew { get; set; }
    public string Kind { get; set; } = "breakpoint";
    public bool IsOn { get; set; } = true;
    public string Name { get; set; } = "";
    public string Host { get; set; } = "";
    public string Path { get; set; } = "";
    /// <summary>Empty for any method.</summary>
    public string Method { get; set; } = "";
    /// <summary>request, response or both.</summary>
    public string Phase { get; set; } = "both";
    public string File { get; set; } = "";
    public int Status { get; set; } = 200;
    /// <summary>Empty to take the type from the file's extension.</summary>
    public string ContentType { get; set; } = "";
    public string Destination { get; set; } = "";
    public List<WireRewriteChange> Changes { get; set; } = [];
    public bool ClosesConnection { get; set; }
    public int BlockStatus { get; set; } = 403;
    public string Code { get; set; } = "";
    /// <summary>The request the rule was made from, for saving its response as Map Local's file.</summary>
    public ulong? Exchange { get; set; }
}

/// <summary>One change of a Rewrite rule.</summary>
public sealed class WireRewriteChange
{
    /// <summary>setHeader, removeHeader, setQueryParameter, removeQueryParameter, replaceBody or setStatus.</summary>
    public string Change { get; set; } = "setHeader";
    public string Part { get; set; } = "request";
    /// <summary>The header or parameter, or the text to find.</summary>
    public string Name { get; set; } = "";
    /// <summary>The value to set, or the text to replace with.</summary>
    public string Value { get; set; } = "";
    public int Status { get; set; } = 200;

    public bool HasPart => Change is "setHeader" or "removeHeader" or "replaceBody";
    public bool HasValue => Change is "setHeader" or "setQueryParameter" or "replaceBody";
}

/// <summary>What the editor shows as you edit a rule: what to fix, the name it gets, and the requests it matches.</summary>
public sealed record WireRuleCheck(string? Problem, string DefaultName, int MatchCount, WireRuleRequest[]? Matching);

/// <summary>A request to try a script on, such as "GET api.weatherly.dev/v2/forecast · 200".</summary>
public sealed record WireRuleRequest(ulong Id, string Description);

public sealed record WireScriptExample(string Id, string Code);

/// <summary>What a script would do to a request, or to its response, and what it logged.</summary>
public sealed record WireScriptTrial(string Part, string Detail, string[] Logs, bool Failed);

/// <summary>How Reqly's own connections go: the upstream proxy, the reverse proxies and the client certificates.</summary>
public sealed record WireConnections(
    WireUpstreamProxy UpstreamProxy, string? ActiveUpstreamProxy, WireReverseProxyRow[] ReverseProxies,
    WireClientCertificate[] ClientCertificates, string? Problem)
{
    public static readonly WireConnections None = new(new WireUpstreamProxy(), null, [], [], null);
}

/// <summary>The upstream proxy as Settings edit it, field for field as the core's draft, with its port as typed.</summary>
public sealed record WireUpstreamProxy
{
    public bool IsOn { get; init; }
    public string Host { get; init; } = "";
    public string Port { get; init; } = "";
    public string Username { get; init; } = "";
    public string Password { get; init; } = "";
    /// <summary>Hosts to reach directly, as typed.</summary>
    public string Bypass { get; init; } = "";
    public bool BypassesLocalAddresses { get; init; } = true;
}

/// <summary>A reverse proxy in the list, such as localhost:8080 → https://api.weatherly.dev, and why it isn't listening, if it isn't.</summary>
public sealed record WireReverseProxyRow(
    Guid Id, bool IsOn, int LocalPort, string ServerURL, bool RewritesRedirects, string LocalAddress, string Server, string? Problem);

/// <summary>A reverse proxy as its editor edits it, with its port as typed.</summary>
public sealed record WireReverseProxy
{
    public Guid Id { get; init; }
    public bool IsOn { get; init; } = true;
    public string Port { get; init; } = "";
    public string ServerURL { get; init; } = "";
    public bool RewritesRedirects { get; init; } = true;
}

/// <summary>A client certificate in the list. Its private key stays in the core.</summary>
public sealed record WireClientCertificate(
    Guid Id, bool IsOn, string Name, string Issuer, string Hosts, double? Expires, bool HasExpired, bool IsMissing);

/// <summary>The .proto files protobuf bodies are read with, what they hold, and what's wrong with them.</summary>
public sealed record WireProtobuf(
    WireProtobufSource[] Sources, string Summary, WireProtobufProblem[] Problems, string? SaveProblem, string[] Types, int Version)
{
    public static readonly WireProtobuf None = new([], "", [], null, [], 0);
}

/// <summary>A .proto file, or a folder of them, and how many it holds: none when it's missing.</summary>
public sealed record WireProtobufSource(string Path, bool IsFolder, string Name, int? Count);

/// <summary>What's wrong in a .proto file, at a line, or with the whole file when the line is 0.</summary>
public sealed record WireProtobufProblem(string File, int Line, string Message);

/// <summary>Phones and tablets on the network: the ones you let in, the ones waiting, and this PC's addresses for them.</summary>
public sealed record WireDevices(
    bool AllowsNetworkDevices, WireKnownDevice[] Known, WireWaitingDevice[] Waiting, WireNetworkAddress[] Addresses, string? Problem)
{
    public static readonly WireDevices None = new(false, [], [], [], null);
}

/// <summary>A device you let in: the name you gave it, if any, its address, and its hardware address when Reqly knows it.</summary>
public sealed record WireKnownDevice(string Id, string? Name, string Address, string? HardwareAddress);

public sealed record WireWaitingDevice(string Id, string Address);

/// <summary>The Android emulators that run, whether Reqly found adb, and why it couldn't ask it, if it couldn't.</summary>
public sealed record WireEmulators(bool HasAdb, WireEmulator[] Emulators, string? Problem);

/// <summary>An emulator: adb's serial, its name, its proxy, and whether that's Reqly.</summary>
public sealed record WireEmulator(string Id, string Name, string? Proxy, bool IsReady, bool UsesReqly);

/// <summary>One of this PC's addresses, on the connection Windows names, such as Wi-Fi.</summary>
public sealed record WireNetworkAddress(string Interface, string Address);

/// <summary>What's wrong with something as you edit it, or a note on what it does once nothing is.</summary>
public sealed record WireCheck(string? Problem, string? Note);

public sealed record WireHostsCheck(string? Problem, int Count);

public static class Wire
{
    /// <summary>Reads the core's JSON, and writes it the way the core reads it, in camelCase.</summary>
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    public static T Read<T>(JsonElement element) => element.Deserialize<T>(Options)!;
}
