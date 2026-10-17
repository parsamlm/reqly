namespace Reqly;

/// <summary>
/// How this run of Reqly is set up, from its command line. Test runs point everything at their
/// own folders and leave your proxy settings alone, as the Mac app's test launches do:
/// <c>--sets-system-proxy no --sessions-folder &lt;dir&gt; --proxy-restore-file &lt;file&gt; --log-file &lt;file&gt;
/// --settings-file &lt;file&gt; --rules-file &lt;file&gt; --connections-file &lt;file&gt; --secrets-stand-in &lt;file&gt;
/// --root-stand-in &lt;file&gt; --port 9191</c>, or <c>--proxy-settings-stand-in &lt;file&gt;</c>
/// to run the proxy switch on a file instead of your settings.
/// </summary>
public sealed class AppOptions
{
    private static readonly string Data =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Reqly");

    public string SessionsFolder { get; private set; } = Path.Combine(Data, "Sessions");
    public string ProxyRestoreFile { get; private set; } = Path.Combine(Data, "ProxyRestore.json");
    /// <summary>Where Reqly notes what it does and why anything failed. It stays on this computer.</summary>
    public string LogFile { get; private set; } = Path.Combine(Data, "Reqly.log");
    /// <summary>
    /// Where each run of Reqly writes what it says as it stops, and where the files of runs that
    /// crashed stay, to offer to report them.
    /// </summary>
    public string CrashReportsFolder { get; private set; } = Path.Combine(Data, "Crashes");
    public string SettingsFile { get; private set; } = Path.Combine(Data, "Settings.json");
    /// <summary>The rules, in the same JSON the Mac keeps them in.</summary>
    public string RulesFile { get; private set; } = Path.Combine(Data, "Rules.json");
    /// <summary>The devices you let in, and the names you gave devices, as the Mac keeps them.</summary>
    public string DevicesFile { get; private set; } = Path.Combine(Data, "Devices.json");
    /// <summary>For test runs: yes leaves the welcome guide closed, as if it had opened before.</summary>
    public bool HasSeenWelcome { get; private set; }
    /// <summary>For test runs: yes goes past agreeing to Microsoft's terms at the first launch, as if you had.</summary>
    public bool HasAgreedToTerms { get; private set; }
    /// <summary>For test runs: no keeps Reqly from checking for a newer version, in place of the choice in Settings.</summary>
    public bool? ChecksForUpdates { get; private set; }
    /// <summary>For test runs: a folder of Reqly's packages and their feed, as package.ps1 leaves them, to update from in place of GitHub.</summary>
    public string? UpdatesFrom { get; private set; }
    /// <summary>For test runs: crashes Reqly once its window shows, in Swift's runtime or in .NET, to report it at the next launch: swift, swift-here, dotnet, timer or queue.</summary>
    public string? SmokeCrash { get; private set; }
    /// <summary>For test runs: whether devices on the network may connect, in place of the choice in Settings. No keeps Reqly off the network.</summary>
    public bool? AllowsNetworkDevices { get; private set; }
    /// <summary>The .proto files bodies are read with, and the message types chosen, as the Mac keeps them.</summary>
    public string ProtobufFile { get; private set; } = Path.Combine(Data, "Protobuf.json");
    /// <summary>The upstream proxy, the reverse proxies and the client certificates, as the Mac keeps them.</summary>
    public string ConnectionsFile { get; private set; } = Path.Combine(Data, "Connections.json");
    /// <summary>The upstream proxy's password and the client certificates' keys, in a file Windows encrypts for your user account.</summary>
    public string SecretsFile { get; private set; } = Path.Combine(Data, "Secrets.dat");
    /// <summary>For test runs: a plain file for the secrets instead, so the run needs nothing of your account.</summary>
    public string? SecretsStandIn { get; private set; }
    /// <summary>Reqly's certificate and its key, in a file Windows encrypts for your user account.</summary>
    public string RootFile { get; private set; } = Path.Combine(Data, "Certificate.dat");
    /// <summary>
    /// For test runs: a plain file for a certificate that counts as trusted, so the run decrypts
    /// while Windows never trusts it, and Windows' certificate stores stay untouched.
    /// </summary>
    public string? RootStandIn { get; private set; }
    /// <summary>For test runs: a JSON file that stands in for Windows' proxy settings, so the switch runs without changing yours.</summary>
    public string? ProxySettingsStandIn { get; private set; }
    public bool SetsSystemProxy { get; private set; } = true;
    /// <summary>For test runs: the port, in place of the one in Settings.</summary>
    public int? Port { get; private set; }
    /// <summary>For test runs: whether capturing starts at once, in place of the choice in Settings.</summary>
    public bool? StartsCapturing { get; private set; }
    /// <summary>With --smoke &lt;file&gt;: sends a request through Reqly, writes what happened to the file, and quits.</summary>
    public string? SmokeReport { get; private set; }
    /// <summary>For test runs: the self-check's parts to run, such as "devices,welcome", or all of them.</summary>
    public string[]? SmokeParts { get; private set; }

    /// <summary>With --smoke-session &lt;file&gt;: a session another system saved, which the self-check opens and reads.</summary>
    public string? SmokeSession { get; private set; }
    /// <summary>For test runs: a PEM file of root certificates to trust when checking servers, such as a test website's.</summary>
    public string? TrustRoots { get; private set; }
    /// <summary>For test runs: light or dark, whatever Windows uses, for pictures of both.</summary>
    public string? Theme { get; private set; }

    /// <summary>Saved sessions and HAR files to open, such as when you open one from File Explorer.</summary>
    public List<string> FilesToOpen { get; } = [];

    public static AppOptions Parse(string[] arguments)
    {
        var options = new AppOptions();
        for (var index = 0; index < arguments.Length; index += 2)
        {
            if (!arguments[index].StartsWith("--"))
            {
                options.FilesToOpen.Add(arguments[index]);
                index -= 1;
                continue;
            }
            if (index + 1 >= arguments.Length)
            {
                break;
            }
            var value = arguments[index + 1];
            switch (arguments[index])
            {
                case "--sessions-folder": options.SessionsFolder = value; break;
                case "--proxy-restore-file": options.ProxyRestoreFile = value; break;
                case "--log-file": options.LogFile = value; break;
                case "--crash-reports-folder": options.CrashReportsFolder = value; break;
                case "--settings-file": options.SettingsFile = value; break;
                case "--rules-file": options.RulesFile = value; break;
                case "--connections-file": options.ConnectionsFile = value; break;
                case "--protobuf-file": options.ProtobufFile = value; break;
                case "--devices-file": options.DevicesFile = value; break;
                case "--has-seen-welcome": options.HasSeenWelcome = value != "no"; break;
                case "--has-agreed-to-terms": options.HasAgreedToTerms = value != "no"; break;
                case "--checks-for-updates": options.ChecksForUpdates = value != "no"; break;
                case "--updates-from": options.UpdatesFrom = value; break;
                case "--smoke-crash": options.SmokeCrash = value; break;
                case "--allows-network-devices": options.AllowsNetworkDevices = value != "no"; break;
                case "--secrets-stand-in": options.SecretsStandIn = value; break;
                case "--root-file": options.RootFile = value; break;
                case "--root-stand-in": options.RootStandIn = value; break;
                case "--proxy-settings-stand-in": options.ProxySettingsStandIn = value; break;
                case "--sets-system-proxy": options.SetsSystemProxy = value != "no"; break;
                case "--port": options.Port = int.TryParse(value, out var port) ? port : null; break;
                case "--starts-capturing": options.StartsCapturing = value != "no"; break;
                case "--smoke": options.SmokeReport = value; break;
                case "--smoke-parts": options.SmokeParts = value.Split(','); break;
                case "--smoke-session": options.SmokeSession = value; break;
                case "--trust-roots": options.TrustRoots = value; break;
                case "--theme": options.Theme = value; break;
                default: index -= 1; break;
            }
        }
        return options;
    }
}
