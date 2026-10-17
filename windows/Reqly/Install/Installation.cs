using Reqly.Core;

namespace Reqly.Install;

/// <summary>
/// Reqly as its installer, Velopack, puts it on a PC: what happens as Reqly is installed, updated
/// and uninstalled, which <see cref="Program.Main"/> hands Velopack. Velopack installs Reqly for
/// your user alone, under <c>%LOCALAPPDATA%\Reqly.App</c>, apart from your settings and sessions
/// in <c>%LOCALAPPDATA%\Reqly</c>, which uninstalling leaves.
/// </summary>
internal static class Installation
{
    /// <summary>Reqly was installed or updated: it opens the files it opens.</summary>
    public static void Installed() => FileTypes.Register();

    /// <summary>
    /// Reqly is about to be uninstalled: it takes back what it set outside its own folders. Your
    /// settings and sessions stay.
    /// </summary>
    public static void Uninstalling()
    {
        FileTypes.Remove();
        var options = AppOptions.Parse([]);
        // A Reqly that crashed may have left your proxy settings pointing at itself.
        try
        {
            CoreSession.RestoreProxy(options.ProxyRestoreFile);
        }
        catch (Exception error)
        {
            AppLog.Write($"couldn't check the proxy settings while uninstalling: {error.Message}");
        }
        // Reqly's certificate leaves your trusted roots, with its key, so nothing goes on trusting
        // what Reqly signed. Windows asks you to confirm; saying no keeps it.
        try
        {
            CoreSession.RemoveRoot(options.RootFile, standIn: false);
        }
        catch (Exception error)
        {
            AppLog.Write($"couldn't remove Reqly's certificate while uninstalling: {error.Message}");
        }
    }
}
