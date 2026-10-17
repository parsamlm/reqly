using System.Text.Json;
using System.Text.Json.Nodes;
using Reqly.Core;
using Reqly.Settings;

namespace Reqly.Https;

/// <summary>
/// Reqly's certificate for HTTPS decryption, and the hosts to decrypt, as the Mac app's HTTPS
/// model keeps them. The core keeps the certificate in your user's certificate store, and
/// decrypts only while Windows trusts it, and only the hosts on the list; everything else passes
/// through untouched. The list is kept in your settings.
/// </summary>
public sealed class HttpsModel(CoreSession session, AppSettings settings)
{
    public enum Phase
    {
        Checking,
        /// <summary>No certificate yet.</summary>
        NotSetUp,
        /// <summary>The certificate exists, but Windows doesn't trust it, so nothing is decrypted.</summary>
        NotTrusted,
        Trusted,
        /// <summary>Busy, such as while Windows asks you to confirm. <see cref="Message"/> says what with.</summary>
        Working,
        /// <summary>Setting up or removing failed. <see cref="Message"/> says why.</summary>
        Failed,
    }

    private WireHttps? state;
    /// <summary>A host to decrypt as soon as setup finishes.</summary>
    private string? hostAfterSetup;

    public Phase Status { get; private set; } = Phase.Checking;
    public string? Message { get; private set; }
    public WireHosts Hosts => state?.Hosts ?? settings.DecryptedHosts;
    public bool IsTrusted => Status == Phase.Trusted;
    public bool IsWorking => Status == Phase.Working;
    public bool HasCertificate => state?.CertificateName is not null;
    /// <summary>The certificate's name in Windows' certificate manager, and when it was made.</summary>
    public (string Name, DateTime Created)? Certificate =>
        state is { CertificateName: { } name, Created: double created }
            ? (name, DateTime.UnixEpoch.AddSeconds(created).ToLocalTime())
            : null;
    /// <summary>The certificate in DER, for devices to install, while Windows trusts it.</summary>
    public byte[]? CertificateForDevices =>
        IsTrusted && state?.Certificate is { } text ? Convert.FromBase64String(text) : null;

    /// <summary>The status, the certificate or the hosts changed.</summary>
    public event Action? Changed;
    /// <summary>Setup should show, because a host is to be decrypted before Windows trusts the certificate.</summary>
    public event Action? SetupRequested;

    /// <summary>Hands the core the hosts you saved, and reads whether HTTPS is set up.</summary>
    public async Task LoadAsync()
    {
        var saved = new JsonObject
        {
            ["call"] = "setDecryptedHosts",
            ["hosts"] = JsonSerializer.SerializeToNode(settings.DecryptedHosts, Wire.Options),
        };
        try
        {
            Apply(Wire.Read<WireHttps>(await session.CallAsync(saved)));
        }
        catch (CoreProblem problem)
        {
            // Hosts the core can't read at all, such as from a file edited by hand, are left out.
            AppLog.Write($"couldn't use the saved hosts: {problem.Message}");
            try
            {
                Apply(Wire.Read<WireHttps>(await session.CallAsync(new JsonObject { ["call"] = "https" })));
            }
            catch (CoreProblem failure)
            {
                Show(Phase.Failed, failure.Message);
            }
        }
    }

    /// <summary>
    /// Makes the certificate if there isn't one, then asks Windows to trust it. Windows asks you to
    /// confirm; saying no isn't a failure, and leaves the certificate untrusted.
    /// </summary>
    public async Task SetUpAsync()
    {
        Show(Phase.Working, "Waiting for you to confirm…");
        try
        {
            Apply(Wire.Read<WireHttps>(await session.CallAsync(new JsonObject { ["call"] = "setUpHTTPS" })));
            AppLog.Write($"HTTPS set up: {state?.Status}");
        }
        catch (CoreProblem problem)
        {
            AppLog.Write($"couldn't set up HTTPS: {problem.Message}");
            Show(Phase.Failed, problem.Message);
            return;
        }
        if (IsTrusted && hostAfterSetup is { } host)
        {
            hostAfterSetup = null;
            await DecryptAsync(host);
        }
    }

    /// <summary>Removes the certificate, its key and Windows' trust in it. Windows asks you to confirm.</summary>
    public async Task RemoveAsync()
    {
        Show(Phase.Working, "Removing Reqly's certificate…");
        try
        {
            Apply(Wire.Read<WireHttps>(await session.CallAsync(new JsonObject { ["call"] = "removeHTTPS" })));
            AppLog.Write($"HTTPS removed: {state?.Status}");
        }
        catch (CoreProblem problem)
        {
            AppLog.Write($"couldn't remove HTTPS: {problem.Message}");
            Show(Phase.Failed, problem.Message);
        }
    }

    /// <summary>Forgets a host waiting for setup, as closing setup does.</summary>
    public void CancelSetup()
    {
        hostAfterSetup = null;
        if (Status == Phase.Failed)
        {
            Show(HasCertificate ? Phase.NotTrusted : Phase.NotSetUp, null);
        }
    }

    /// <summary>
    /// Decrypts a host from now on: switches its entry on, or adds one. Before Windows trusts the
    /// certificate, it shows setup first.
    /// </summary>
    public async Task DecryptAsync(string host)
    {
        if (!IsTrusted)
        {
            hostAfterSetup = host;
            SetupRequested?.Invoke();
            return;
        }
        await ChangeAsync(new JsonObject { ["call"] = "decryptHost", ["host"] = host });
    }

    /// <summary>Stops decrypting a host. It stays on the list switched off, so a wildcard leaves it alone.</summary>
    public Task StopDecryptingAsync(string host) =>
        ChangeAsync(new JsonObject { ["call"] = "stopDecryptingHost", ["host"] = host });

    /// <summary>Adds a host to the list, switched on, or says why it can't.</summary>
    public async Task<string?> AddHostAsync(string text)
    {
        try
        {
            var request = new JsonObject { ["call"] = "addDecryptedHost", ["text"] = text };
            Apply(Wire.Read<WireHttps>(await session.CallAsync(request)));
            Save();
            return null;
        }
        catch (CoreProblem problem)
        {
            return problem.Message;
        }
    }

    public Task RemoveHostAsync(string pattern) =>
        ChangeAsync(new JsonObject { ["call"] = "removeDecryptedHosts", ["patterns"] = new JsonArray(pattern) });

    public Task SetDecryptsAsync(string pattern, bool isOn) =>
        ChangeAsync(new JsonObject { ["call"] = "setHostDecrypted", ["pattern"] = pattern, ["isOn"] = isOn });

    public Task SetDecryptsEveryHostAsync(bool isOn) =>
        ChangeAsync(new JsonObject { ["call"] = "setDecryptsEveryHost", ["isOn"] = isOn });

    /// <summary>Whether Reqly decrypts a host now.</summary>
    public async Task<bool> DecryptsAsync(string host)
    {
        try
        {
            var reply = await session.CallAsync(new JsonObject { ["call"] = "decryptsHost", ["host"] = host });
            return reply.GetProperty("decrypts").GetBoolean();
        }
        catch (CoreProblem)
        {
            return false;
        }
    }

    private async Task ChangeAsync(JsonObject request)
    {
        try
        {
            Apply(Wire.Read<WireHttps>(await session.CallAsync(request)));
            Save();
        }
        catch (CoreProblem problem)
        {
            AppLog.Write($"couldn't change HTTPS: {problem.Code}: {problem.Message}");
        }
    }

    private void Apply(WireHttps wire)
    {
        state = wire;
        Show(wire.Status switch
        {
            "trusted" => Phase.Trusted,
            "notTrusted" => Phase.NotTrusted,
            _ => Phase.NotSetUp,
        }, null);
    }

    private void Show(Phase status, string? message)
    {
        Status = status;
        Message = message;
        Changed?.Invoke();
    }

    private void Save()
    {
        settings.DecryptedHosts = Hosts;
        settings.Save();
    }
}
