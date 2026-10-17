using Microsoft.UI.Dispatching;
using Reqly.Help;
using Reqly.Settings;
using Velopack;
using Velopack.Sources;

namespace Reqly.Updates;

/// <summary>
/// Reqly's updates, from its releases on GitHub, as Velopack installs them, as Sparkle updates the
/// Mac app: a check a day while Settings › General allow it, and whenever you choose Check for
/// updates. An update downloads in the background and installs when Reqly quits, or when you
/// restart Reqly to update. Only an installed Reqly updates itself; a copy built from the source
/// doesn't, and neither do test runs.
/// </summary>
public sealed class UpdatesModel
{
    /// <summary>Where checking got to, as Settings › General shows it.</summary>
    public enum State
    {
        NotChecked,
        Checking,
        UpToDate,
        Ready,
        Failed,
    }

    private static readonly TimeSpan FirstCheck = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan Between = TimeSpan.FromDays(1);

    private readonly AppSettings settings;
    private readonly bool isAllowed;
    private readonly UpdateManager manager;
    private DispatcherQueueTimer? timer;
    /// <summary>The update that's downloaded and installs when Reqly quits.</summary>
    private UpdateInfo? downloaded;
    private Task<string>? checking;
    private bool isInstalling;

    /// <param name="folder">For test runs: a folder of packages to update from, in place of GitHub.</param>
    public UpdatesModel(AppSettings settings, bool isAllowed, string? folder = null)
    {
        this.settings = settings;
        this.isAllowed = isAllowed;
        // A beta looks for betas too; a release, for releases.
        manager = new UpdateManager(folder is null
            ? new GithubSource(AppInfo.SourceCode.ToString(), accessToken: null, prerelease: AppInfo.Version.Contains('-'))
            : new SimpleFileSource(new DirectoryInfo(folder)));
    }

    /// <summary>Whether this copy of Reqly updates itself: an installed one, outside test runs.</summary>
    public bool CanUpdate => isAllowed && manager.IsInstalled;

    /// <summary>The version that's downloaded and installs when Reqly quits, if there is one.</summary>
    public string? ReadyVersion => downloaded?.TargetFullRelease.Version.ToString();

    public State Status { get; private set; }

    /// <summary>Why the last check failed, while it's the last one.</summary>
    public string? Problem { get; private set; }

    /// <summary>Where checking got to, in words, as Settings › General and Check for updates say it.</summary>
    public string Description => (CanUpdate, Status) switch
    {
        (false, _) => isAllowed
            ? "This copy of Reqly wasn't installed with its installer, so it doesn't update itself."
            : "Test runs of Reqly don't update themselves.",
        (_, State.Checking) => "Checking…",
        (_, State.UpToDate) => "You're up to date.",
        (_, State.Ready) => $"Reqly {ReadyVersion} is ready. It installs when Reqly quits.",
        (_, State.Failed) => $"Reqly couldn't check for updates. {Problem}",
        _ => settings.LastCheckedForUpdates is { } last
            ? $"Last checked {last.ToLocalTime():g}."
            : "Reqly looks for updates on GitHub.",
    };

    /// <summary>Checking started or stopped, or an update finished downloading.</summary>
    public event Action? Changed;

    /// <summary>Checks a little after Reqly opens, then once a day, while Settings allow it.</summary>
    public void Start(DispatcherQueue queue)
    {
        if (!CanUpdate)
        {
            return;
        }
        timer = queue.CreateTimer();
        timer.Interval = FirstCheck;
        timer.Tick += CrashReports.Reported.Tick(() =>
        {
            timer.Interval = Between;
            if (settings.ChecksForUpdates)
            {
                _ = CheckAsync();
            }
        });
        timer.Start();
    }

    /// <summary>
    /// Asks GitHub for a newer version, and downloads it if there is one. Says what it found, as
    /// Check for updates shows it.
    /// </summary>
    public async Task<string> CheckAsync()
    {
        // A check already on its way answers this one too.
        if (checking is { } running)
        {
            return await running;
        }
        checking = CheckOnceAsync();
        try
        {
            return await checking;
        }
        finally
        {
            checking = null;
        }
    }

    private async Task<string> CheckOnceAsync()
    {
        if (!CanUpdate || downloaded is not null)
        {
            return Description;
        }
        Show(State.Checking);
        try
        {
            var update = await manager.CheckForUpdatesAsync();
            settings.LastCheckedForUpdates = DateTime.UtcNow;
            settings.Save();
            if (update is null)
            {
                AppLog.Write("checked for updates: this is the newest Reqly");
                Show(State.UpToDate);
                return Description;
            }
            AppLog.Write($"downloading Reqly {update.TargetFullRelease.Version}");
            await manager.DownloadUpdatesAsync(update);
            downloaded = update;
            AppLog.Write($"Reqly {ReadyVersion} is ready to install");
            Show(State.Ready);
        }
        catch (Exception error)
        {
            AppLog.Write($"couldn't check for updates: {error.Message}");
            Problem = error.Message;
            Show(State.Failed);
        }
        return Description;
    }

    private void Show(State state)
    {
        Status = state;
        Changed?.Invoke();
    }

    /// <summary>
    /// Has the downloaded update install once Reqly quits, quietly, or with Reqly starting again
    /// afterwards, when you restart Reqly to update. Does nothing without one.
    /// </summary>
    public void InstallOnQuit(bool restarts)
    {
        if (downloaded is not { } update || isInstalling)
        {
            return;
        }
        isInstalling = true;
        AppLog.Write($"installing Reqly {ReadyVersion} once Reqly quits{(restarts ? ", then opening it again" : "")}");
        manager.WaitExitThenApplyUpdates(update.TargetFullRelease, silent: !restarts, restart: restarts);
    }
}
