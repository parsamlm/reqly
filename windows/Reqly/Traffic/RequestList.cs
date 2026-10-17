using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Reqly.Core;

namespace Reqly.Traffic;

/// <summary>
/// The request list, kept in step with the core: its "rows" events say how the rows change and
/// name each new row's exchange, and the rows' contents come from "rows" calls. The core does the
/// filtering and searching, with the same list engine as the Mac app.
/// </summary>
public sealed class RequestList(CoreSession session)
{
    /// <summary>Rows asked for in one call.</summary>
    private const int Batch = 500;

    public ObservableCollection<RequestRow> Rows { get; } = [];

    /// <summary>How many exchanges the session has, shown or not.</summary>
    public int Total { get; private set; }

    public event Action? Changed;

    private readonly Dictionary<ulong, RequestRow> byID = [];
    private readonly HashSet<ulong> wanted = [];
    private bool isFetching;

    /// <summary>The row that shows an exchange, while one does.</summary>
    public RequestRow? Row(ulong id) => byID.GetValueOrDefault(id);

    /// <summary>Has every row read its colors again, as after light or dark mode changed.</summary>
    public void RefreshRows()
    {
        foreach (var row in Rows)
        {
            row.Refresh();
        }
    }

    /// <summary>
    /// Takes in a "rows" event: rows removed, rows inserted, rows changed, or every row. A burst of
    /// traffic can bring a thousand rows in one event, and the list redoes its layout for each row
    /// it gains, so the rows go in a few milliseconds' worth at a time, with the window free to
    /// answer you in between. Events wait their turn, since each one's row numbers count on the
    /// ones before it.
    /// </summary>
    public void Apply(JsonElement update)
    {
        pending.Enqueue(new Update(update));
        if (!isApplying)
        {
            ApplySome();
        }
    }

    /// <summary>How long the rows may take in one go before the window gets its turn.</summary>
    private static readonly TimeSpan Slice = TimeSpan.FromMilliseconds(8);

    private readonly Queue<Update> pending = new();
    private bool isApplying;
    /// <summary>
    /// When the list last brought its newest row into view. Each time, it lays out a screen of
    /// new rows, so during a burst it does that ten times a second at most, then once at the end.
    /// </summary>
    private readonly Stopwatch sinceRevealed = Stopwatch.StartNew();
    private static readonly TimeSpan RevealEvery = TimeSpan.FromMilliseconds(100);
    private bool isFollowing;
    private bool hasUnrevealedRows;

    /// <summary>Whether the list shows its last row, asked before rows go in: a list there follows new traffic, as on the Mac.</summary>
    public Func<bool>? ShowsEnd { get; set; }

    /// <summary>Brings a row into view, such as the newest, for a list that follows new traffic.</summary>
    public Action<RequestRow>? Reveal { get; set; }

    private void ApplySome()
    {
        isApplying = true;
        var started = Stopwatch.StartNew();
        // While new rows wait to be revealed, the list isn't at its end, but it's still following.
        var follows = (isFollowing && hasUnrevealedRows) || ShowsEnd?.Invoke() == true;
        var before = Rows.Count;
        while (pending.TryPeek(out var update) && started.Elapsed < Slice)
        {
            if (update.ApplySome(this, started))
            {
                pending.Dequeue();
                Total = update.Total;
            }
        }
        hasUnrevealedRows = follows && (hasUnrevealedRows || Rows.Count != before);
        if (hasUnrevealedRows && Rows.Count > 0 && (pending.Count == 0 || sinceRevealed.Elapsed >= RevealEvery))
        {
            Reveal?.Invoke(Rows[^1]);
            hasUnrevealedRows = false;
            sinceRevealed.Restart();
        }
        isFollowing = follows;
        Changed?.Invoke();
        if (pending.Count == 0 || !DispatcherQueue.GetForCurrentThread().TryEnqueue(DispatcherQueuePriority.Low, CrashReports.Reported.Queued(ApplySome)))
        {
            isApplying = false;
        }
    }

    /// <summary>A "rows" event, read once, and how far into it the list has got.</summary>
    private sealed class Update
    {
        private readonly List<(string Kind, ulong[] Ids, int[] Rows)> steps = [];
        private int step;
        private int done;

        public int Total { get; }

        public Update(JsonElement update)
        {
            Total = update.GetProperty("total").GetInt32();
            foreach (var each in update.GetProperty("steps").EnumerateArray())
            {
                if (each.TryGetProperty("removed", out var removed))
                {
                    // From the last, so the row numbers before it stay as they were.
                    steps.Add(("removed", [], [.. removed.EnumerateArray().Select(row => row.GetInt32()).Reverse()]));
                }
                else if (each.TryGetProperty("inserted", out var inserted))
                {
                    var entries = inserted.EnumerateArray().ToList();
                    steps.Add(("inserted", [.. entries.Select(entry => entry.GetProperty("id").GetUInt64())],
                        [.. entries.Select(entry => entry.GetProperty("row").GetInt32())]));
                }
                else if (each.TryGetProperty("changed", out var changed))
                {
                    steps.Add(("changed", [.. changed.EnumerateArray().Select(id => id.GetUInt64())], []));
                }
                else if (each.TryGetProperty("reset", out var reset))
                {
                    steps.Add(("reset", [.. reset.EnumerateArray().Select(id => id.GetUInt64())], []));
                }
            }
        }

        /// <summary>Applies the next rows, until the slice is up. Returns whether every step is done.</summary>
        public bool ApplySome(RequestList list, Stopwatch started)
        {
            while (step < steps.Count)
            {
                var (kind, ids, rows) = steps[step];
                var count = kind == "removed" ? rows.Length : ids.Length;
                if (kind == "reset" && done == 0)
                {
                    list.Rows.Clear();
                    list.byID.Clear();
                }
                while (done < count)
                {
                    switch (kind)
                    {
                        case "removed":
                            list.byID.Remove(list.Rows[rows[done]].ID);
                            list.Rows.RemoveAt(rows[done]);
                            break;
                        case "inserted":
                            var inserted = new RequestRow(ids[done]);
                            list.byID[inserted.ID] = inserted;
                            list.Rows.Insert(rows[done], inserted);
                            list.Want(inserted.ID);
                            break;
                        case "changed":
                            list.Want(ids[done]);
                            break;
                        case "reset":
                            var row = new RequestRow(ids[done]);
                            list.byID[row.ID] = row;
                            list.Rows.Add(row);
                            list.Want(row.ID);
                            break;
                    }
                    done++;
                    // Every so often, to keep the clock's cost down.
                    if (done % 16 == 0 && started.Elapsed >= Slice)
                    {
                        return false;
                    }
                }
                step++;
                done = 0;
            }
            return true;
        }
    }

    private void Want(ulong id)
    {
        wanted.Add(id);
        if (!isFetching)
        {
            isFetching = true;
            _ = FetchAsync();
        }
    }

    /// <summary>Asks for the rows that are new or changed, a batch at a time, then fills them in.</summary>
    private async Task FetchAsync()
    {
        try
        {
            // Changes that come together are asked for together.
            await Task.Yield();
            while (wanted.Count > 0)
            {
                var ids = wanted.Take(Batch).ToArray();
                wanted.ExceptWith(ids);
                var request = new JsonObject
                {
                    ["call"] = "rows",
                    ["ids"] = new JsonArray(ids.Select(id => (JsonNode)JsonValue.Create(id)).ToArray()),
                };
                var result = await session.CallAsync(request);
                foreach (var element in result.GetProperty("rows").EnumerateArray())
                {
                    var wire = Wire.Read<WireRow>(element);
                    if (byID.TryGetValue(wire.Id, out var row))
                    {
                        row.Load(wire);
                    }
                }
                // A row's contents can change what the window says about it, such as its details.
                Changed?.Invoke();
            }
        }
        finally
        {
            isFetching = false;
        }
    }
}

/// <summary>
/// A row of the list, as the Mac's table shows it. Its exchange's contents fill in when they
/// arrive. Its text reads as the row's description, which screen readers say.
/// </summary>
public sealed class RequestRow(ulong id) : INotifyPropertyChanged
{
    public ulong ID { get; } = id;
    public WireRow? Contents { get; private set; }

    public event PropertyChangedEventHandler? PropertyChanged;

    private bool isSelected;

    /// <summary>The icon of the app that sent the request, once it's loaded.</summary>
    public ImageSource? AppIcon { get; private set; }

    public void Load(WireRow contents)
    {
        var program = contents.AppPath;
        var isNewApp = Contents is null || program != Contents.AppPath;
        Contents = contents;
        Refresh();
        if (isNewApp)
        {
            _ = LoadIconAsync(program);
        }
    }

    /// <summary>Says every property changed, such as after light or dark mode changed the colors.</summary>
    public void Refresh() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));

    private async Task LoadIconAsync(string? program)
    {
        var icon = program is null ? null : await AppIcons.GetAsync(program);
        if (Contents?.AppPath == program && AppIcon != icon)
        {
            AppIcon = icon;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(AppIcon)));
        }
    }

    public bool IsTunnel => Contents?.Kind == "tunnel";
    public bool IsReadable => Contents?.Kind == "http";
    private bool IsFailed => Contents?.State == "failed";
    private bool IsPaused => Contents?.State == "paused";
    private bool HasCode => Contents?.Status is not null && !IsFailed && !IsPaused && !IsTunnel;

    // MARK: Status

    /// <summary>The code, such as 200, or Failed or Paused. A tunnel and a request in progress have none.</summary>
    public string Status => Contents switch
    {
        null => "",
        _ when IsFailed => "Failed",
        _ when IsPaused => "Paused",
        _ when IsTunnel => "",
        { Status: int status } => status.ToString(),
        _ => "",
    };

    public Brush DotBrush => Palette.Status(Contents?.StatusClass);
    public Visibility DotVisibility => Show(HasCode);
    public Visibility FailedVisibility => Show(IsFailed);
    public Visibility PausedVisibility => Show(IsPaused);
    /// <summary>A lock in place of a status, for an encrypted connection that passed through.</summary>
    public Visibility LockVisibility => Show(IsTunnel && !IsFailed && !IsPaused);
    /// <summary>A dotted circle, while the request waits for its response.</summary>
    public Visibility ProgressVisibility => Show(ShowsProgress);

    // What the row's rarely shown icons read, so they're made only for the rows that show them.
    public bool ShowsFailed => IsFailed;
    public bool ShowsPaused => IsPaused;
    public bool ShowsLock => IsTunnel && !IsFailed && !IsPaused;
    public bool ShowsProgress => Contents is not null && !HasCode && !IsFailed && !IsPaused && !IsTunnel;

    /// <summary>What a gRPC call's status says, when it isn't OK, as the status's tooltip.</summary>
    public string? StatusTip => Contents is { Status: int status, GrpcStatus: int code, GrpcTitle: { } title }
        ? $"{status}, gRPC status {code} {title.ToLowerInvariant()}"
        : null;

    /// <summary>The status in words, for screen readers and for rows without a code.</summary>
    public string StatusDescription => Contents switch
    {
        null => "",
        _ when IsFailed => "Failed",
        { State: "paused" } => "Paused at a breakpoint",
        _ when IsTunnel => Contents.State == "open" ? "Encrypted connection, open" : "Encrypted connection",
        _ when StatusTip is { } tip => tip,
        { Status: int status } => status.ToString(),
        _ => "In progress",
    };

    // MARK: The other columns

    public string Method => Contents?.Method ?? "";

    /// <summary>The host, with the port when it isn't the scheme's own.</summary>
    public string DisplayHost => Contents is { } row
        ? (row.Scheme, row.Port) is ("http", 80) or ("https", 443) ? row.Host : $"{row.Host}:{row.Port}"
        : "";

    public string Host => Contents?.Host ?? "";

    /// <summary>What follows the host: the path and query, or what an encrypted connection is.</summary>
    public string Rest => IsTunnel ? "  Encrypted connection" : Contents?.Target ?? "";

    public string App => Contents?.App ?? Contents?.Device ?? "";
    public string Time => Contents is { } row ? Format.Time(row.Started) : "";
    public string Duration => Format.Duration(Contents?.Duration);
    public string Size => Contents is { } row && (row.BytesReceived > 0 || row.State == "completed")
        ? Format.Size(row.BytesReceived)
        : "";

    // MARK: Pins, marks and comments

    /// <summary>Whether the list has this row selected, as its selection changes.</summary>
    public bool IsSelected
    {
        get => isSelected;
        set
        {
            if (isSelected != value)
            {
                isSelected = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(MarkVisibility)));
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(ShowsMark)));
            }
        }
    }

    public bool IsPinned => Contents?.IsPinned == true;
    public string? Comment => Contents?.Comment;
    public string? Color => Contents?.Color;
    public Visibility PinVisibility => Show(IsPinned);
    public bool HasComment => Comment is not null;
    public Visibility CommentVisibility => Show(HasComment);
    /// <summary>A selected row shows the list's selection mark in place of its color's stripe; its tint stays.</summary>
    public Visibility MarkVisibility => Show(ShowsMark);
    public bool ShowsMark => Color is not null && !IsSelected;
    public Brush? MarkBrush => Color is { } color ? Palette.Mark(color) : null;
    /// <summary>A marked row is tinted with its mark's color, faintly.</summary>
    public Brush? Tint => Color is { } color ? Palette.Tint(color) : null;

    public override string ToString()
    {
        var parts = new List<string> { StatusDescription, Method, DisplayHost + Rest.TrimStart() };
        if (App.Length > 0)
        {
            parts.Add(App);
        }
        if (IsPinned)
        {
            parts.Add("pinned");
        }
        if (Color is { } color)
        {
            parts.Add($"marked {color}");
        }
        if (Comment is { } comment)
        {
            parts.Add($"comment: {comment}");
        }
        return string.Join(", ", parts.Where(part => part.Length > 0));
    }

    private static Visibility Show(bool isShown) => isShown ? Visibility.Visible : Visibility.Collapsed;
}

/// <summary>Sizes, durations, times and counts, as the Mac app writes them, in the user's own number format.</summary>
public static class Format
{
    /// <summary>Bytes under 1,000 as they are; then KB, MB, GB and TB, by thousands, with a decimal below 100.</summary>
    public static string Size(long bytes)
    {
        if (bytes < 1000)
        {
            return $"{bytes:N0} B";
        }
        string[] units = ["KB", "MB", "GB", "TB"];
        var value = bytes / 1000.0;
        var unit = 0;
        while (value >= 1000 && unit < units.Length - 1)
        {
            value /= 1000;
            unit++;
        }
        return value < 100 ? $"{value:N1} {units[unit]}" : $"{value:N0} {units[unit]}";
    }

    /// <summary>340 ms, 1.24 s, 4 min 12 s or 2 h 5 min. With tenths, times under 10 ms keep a tenth, such as 0.4 ms, for the Timing tab's short steps.</summary>
    public static string Duration(double? seconds, bool showingTenths = false)
    {
        if (seconds is not double value)
        {
            return "";
        }
        if (showingTenths && value < 0.00995)
        {
            return $"{value * 1000:N1} ms";
        }
        if (value < 0.9995)
        {
            return $"{Math.Round(value * 1000):N0} ms";
        }
        if (value < 59.995)
        {
            return $"{value:N2} s";
        }
        var whole = (long)Math.Round(value);
        return whole < 3600 ? $"{whole / 60} min {whole % 60} s" : $"{whole / 3600} h {whole % 3600 / 60} min";
    }

    /// <summary>When a request started, in the user's own long time format, such as 14:05:09.</summary>
    public static string Time(double started) =>
        DateTime.UnixEpoch.AddSeconds(started).ToLocalTime().ToString("T");

    public static string Requests(int count) => count == 1 ? "1 request" : $"{count:N0} requests";
}
