using System.Diagnostics;

namespace Reqly.Devices;

/// <summary>
/// What Windows Defender Firewall says about devices reaching Reqly. Windows asks the first time
/// Reqly listens on your network, as macOS asks for the Mac app; turning that down leaves a rule
/// that blocks Reqly, which this finds. Any user can read the rules, so this needs no permission.
/// </summary>
internal static class Firewall
{
    private const int Inbound = 1;
    private const int Block = 0;

    /// <summary>
    /// The kinds of network on which a rule blocks this Reqly from accepting connections, such as
    /// "private", or none. It reads the rules through Windows' firewall interface, which can be slow,
    /// so it runs off the window's thread.
    /// </summary>
    public static Task<string[]> BlockedOnAsync() => Task.Run(() =>
    {
        var program = Environment.ProcessPath;
        if (program is null)
        {
            return Array.Empty<string>();
        }
        try
        {
            var policy = (dynamic)Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FwPolicy2", throwOnError: true)!)!;
            var profiles = 0;
            foreach (dynamic rule in policy.Rules)
            {
                // A rule's values are COM's, so each is read once, into a type.
                string? application = rule.ApplicationName;
                if (application is null)
                {
                    continue;
                }
                int direction = rule.Direction;
                int action = rule.Action;
                bool enabled = rule.Enabled;
                if (direction != Inbound || action != Block || !enabled
                    || !string.Equals(Path.GetFullPath(Environment.ExpandEnvironmentVariables(application)), program, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }
                profiles |= (int)rule.Profiles;
            }
            // Windows' numbers for its kinds of network.
            return new[] { (1, "domain"), (2, "private"), (4, "public") }
                .Where(kind => (profiles & kind.Item1) != 0)
                .Select(kind => kind.Item2)
                .ToArray();
        }
        catch (Exception error)
        {
            AppLog.Write($"couldn't read Windows Firewall's rules: {error.Message}");
            return Array.Empty<string>();
        }
    });

    /// <summary>Opens Windows' list of apps the firewall lets through, where a blocked app can be allowed.</summary>
    public static void OpenSettings() =>
        Process.Start(new ProcessStartInfo("control.exe", "/name Microsoft.WindowsFirewall /page pageConfigureApps") { UseShellExecute = true });
}
