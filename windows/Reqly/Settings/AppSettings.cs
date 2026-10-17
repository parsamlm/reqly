using System.Text.Json;
using Reqly.Core;

namespace Reqly.Settings;

/// <summary>
/// Your settings for Reqly, in a JSON file on this PC. A file that's missing or can't be read
/// reads as the first settings.
/// </summary>
public sealed class AppSettings
{
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
    };

    private string? file;

    /// <summary>The hosts to decrypt, each switched on or off.</summary>
    public WireHosts DecryptedHosts { get; set; } = WireHosts.None;

    /// <summary>Whether saved sessions leave out authorization headers and cookies. They keep them at first.</summary>
    public bool HidesSecretsInSessions { get; set; }

    /// <summary>Whether HAR files leave out authorization headers and cookies, as they do at first, since they're often shared.</summary>
    public bool HidesSecretsInHar { get; set; } = true;

    public bool HarIncludesResponseBodies { get; set; } = true;

    /// <summary>The port Reqly listens on.</summary>
    public int ProxyPort { get; set; } = 9090;

    /// <summary>Whether capturing starts when Reqly opens. As on the Mac, it doesn't at first.</summary>
    public bool StartsCapturingOnLaunch { get; set; }

    /// <summary>Whether phones and tablets on the network may connect, once you let each one in. They can't at first.</summary>
    public bool AllowsNetworkDevices { get; set; }

    /// <summary>Where the main window was, and how big, when it last closed.</summary>
    public WindowPlace? MainWindowPlace { get; set; }

    /// <summary>How wide the details pane was.</summary>
    public double? DetailsWidth { get; set; }

    public bool SidebarIsOpen { get; set; } = true;

    /// <summary>Whether the welcome guide has opened. It opens once, the first time Reqly does.</summary>
    public bool HasSeenWelcome { get; set; }

    /// <summary>
    /// Microsoft's terms you agreed to at the first launch, by a hash of what they said, so terms
    /// that change are asked about again.
    /// </summary>
    public string? AgreedTerms { get; set; }

    /// <summary>Whether Reqly checks for a newer version once a day, as it does at first, as on the Mac.</summary>
    public bool ChecksForUpdates { get; set; } = true;

    /// <summary>When Reqly last asked GitHub for a newer version.</summary>
    public DateTime? LastCheckedForUpdates { get; set; }

    /// <summary>When Reqly last looked for reports of its own crashes, so it offers each once.</summary>
    public DateTime? CrashReportsCheckedAt { get; set; }

    /// <summary>
    /// Whether Reqly has its icon in the notification area, as it does at first. With it, closing
    /// Reqly's window leaves Reqly running there, as on the Mac.
    /// </summary>
    public bool ShowsNotificationIcon { get; set; } = true;

    /// <summary>Whether Reqly has said where it went, the first time its window closed into the notification area.</summary>
    public bool HasSaidItGoesOn { get; set; }

    /// <summary>The list's column widths, from Status to Size, leaving out Request, which takes the rest.</summary>
    public double[]? ListColumnWidths { get; set; }

    public static AppSettings Load(string file)
    {
        AppSettings settings;
        try
        {
            settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(file), Json) ?? new();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            settings = new();
        }
        settings.file = file;
        // A file edited by hand may leave things out.
        settings.DecryptedHosts = settings.DecryptedHosts is { Entries: not null } hosts ? hosts : WireHosts.None;
        return settings;
    }

    public void Save()
    {
        if (file is null)
        {
            return;
        }
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            // Written next to the file, then moved over it, so a crash never leaves half a file.
            var draft = file + ".new";
            File.WriteAllText(draft, JsonSerializer.Serialize(this, Json));
            MoveOver(draft, file);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            AppLog.Write($"couldn't save the settings: {error.Message}");
        }
    }

    /// <summary>
    /// Moves the draft over the file, again for up to about a second while Windows refuses: antivirus
    /// software and the search indexer open new files to read them, and a file can't be replaced while
    /// one of them has it open. The core saves its files the same way.
    /// </summary>
    private static void MoveOver(string draft, string file)
    {
        for (var wait = 10; ; wait *= 2)
        {
            try
            {
                File.Move(draft, file, overwrite: true);
                return;
            }
            catch (Exception error) when (wait < 500 && error is IOException or UnauthorizedAccessException)
            {
                Thread.Sleep(wait);
            }
        }
    }
}

/// <summary>A window's place on the screen, and whether it filled it.</summary>
public sealed record WindowPlace(int X, int Y, int Width, int Height, bool IsMaximized);
