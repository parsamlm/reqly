using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace Reqly.CrashReports;

/// <summary>
/// Offers to report Reqly's last crash on GitHub, as the Mac does. Nothing is sent: Reqly opens a
/// new issue in the browser, filled in from what the crashed run wrote and from the report Windows
/// made of the crash, for you to read, change and submit.
/// </summary>
internal static partial class CrashReporter
{
    /// <summary>A crash to offer to report.</summary>
    /// <param name="File">The full report, to attach to the issue: the run's own file, or Windows'.</param>
    /// <param name="Body">The issue's text, in Markdown, as it opens on GitHub.</param>
    public sealed record Report(string File, DateTime Date, string Title, string Body);

    public static readonly Uri NewIssue = new($"{Help.AppInfo.SourceCode}/issues/new");

    /// <summary>What a run's file is called once its crash was offered, kept to attach to an issue later.</summary>
    private const string Offered = "Crash-";
    private const int OfferedKept = 5;
    private const int FramesShown = 30;

    /// <summary>
    /// The newest crash of this Reqly to offer: a run that left its file with a crash in it, or a
    /// crash that only Windows reported, after <paramref name="since"/>. The first time, with no
    /// <paramref name="since"/>, only the runs' files count. Each crash is offered once: its run's
    /// file is renamed, and the files of runs that ended without one, as when Windows shut down, go.
    /// </summary>
    public static Report? Find(string folder, DateTime? since, string program)
    {
        var fromWindows = WindowsReports(program);
        var crashes = new List<(DateTime Date, string? Run, string Version, Crash? Crash, WindowsReport? Windows)>();
        var matched = new HashSet<WindowsReport>();
        foreach (var run in Runs(folder, program))
        {
            var crash = Crash.Read(run.Text, program);
            var windows = fromWindows.FirstOrDefault(report => report.Time >= run.Started.AddSeconds(-5) && report.Time <= run.Ended.AddMinutes(5));
            if (windows is not null)
            {
                matched.Add(windows);
            }
            if (crash is null && windows is null)
            {
                // It ended some other way, from Task Manager, or as Windows shut down.
                TryDelete(run.Path);
                continue;
            }
            crashes.Add((windows?.Time ?? run.Ended, run.Path, run.Version, crash, windows));
        }
        if (since is { } after)
        {
            foreach (var windows in fromWindows.Where(report => report.Time > after && !matched.Contains(report)))
            {
                crashes.Add((windows.Time, null, VersionOf(windows), null, windows));
            }
        }
        if (crashes.Count == 0)
        {
            return null;
        }
        // Every crash found is offered now, the newest as the report.
        var newest = crashes.MaxBy(crash => crash.Date);
        string? newestFile = null;
        foreach (var crash in crashes.Where(crash => crash.Run is not null))
        {
            var kept = Keep(crash.Run!, crash.Date);
            if (crash.Run == newest.Run)
            {
                newestFile = kept;
            }
        }
        Prune(folder);
        return Describe(newestFile ?? newest.Windows!.File, newest.Version, newest.Crash, newest.Windows, newest.Date);
    }

    /// <summary>A new issue on GitHub, filled in. A body too long for a link is cut short.</summary>
    public static Uri IssueUrl(string title, string body)
    {
        var all = body.Split('\n');
        var lines = all.ToList();
        while (true)
        {
            var text = string.Join('\n', lines);
            if (lines.Count < all.Length)
            {
                // Cut inside a block of frames: close it.
                if (lines.Count(line => line == "```") % 2 == 1)
                {
                    text += "\n…\n```";
                }
                text += "\n\n<sub>Cut short to fit in a link.</sub>";
            }
            var url = $"{NewIssue}?title={Uri.EscapeDataString(title)}&body={Uri.EscapeDataString(text)}";
            // GitHub turns away links much longer than this.
            if (Encoding.UTF8.GetByteCount(url) <= 7_500 || lines.Count <= 1)
            {
                return new Uri(url);
            }
            lines.RemoveAt(lines.Count - 1);
        }
    }

    /// <summary>An issue for a problem that isn't a crash, as Help › Report a problem opens.</summary>
    public static Uri ProblemUrl => IssueUrl("", string.Join('\n',
        "### What happened",
        "<!-- What did you do, what did you expect, and what did Reqly do instead? -->",
        "",
        "",
        "### Details",
        $"- Reqly {Help.AppInfo.Version}",
        $"- {WindowsVersion}"));

    /// <summary>Opens a link in your browser.</summary>
    public static void Open(Uri link) => Process.Start(new ProcessStartInfo(link.AbsoluteUri) { UseShellExecute = true });

    // MARK: Describing a crash

    /// <summary>A crash's facts, in words for an issue, without what could say who you are, such as your user folder's path.</summary>
    private static Report Describe(string file, string version, Crash? crash, WindowsReport? windows, DateTime date)
    {
        var lines = new List<string>
        {
            "### What happened",
            "<!-- What were you doing when Reqly quit? For example: I opened a large JSON response. -->",
            "",
            "",
            "### Crash details",
            $"- Reqly {version}",
            $"- {WindowsVersion}",
        };
        string kind;
        if (crash is not null)
        {
            kind = crash.Kind;
            // Swift's own message says Fatal error already.
            if (crash.Module is not null || crash.Messages.Count == 0 || crash.Kind != "Fatal error")
            {
                lines.Add($"- {crash.Kind}{(crash.Module is { } module ? $" in {module}" : "")}");
            }
            lines.AddRange(crash.Messages.Select(message => $"- {message}"));
        }
        else
        {
            kind = windows!.Code is { } code ? ExceptionName(code) : "Reqly quit unexpectedly";
        }
        if (windows is not null)
        {
            var place = windows.Module is { } module
                ? $" in {module}{(windows.ModuleVersion is { } moduleVersion ? $" {moduleVersion}" : "")}{(windows.Offset is { } offset ? $", at offset {offset}" : "")}"
                : "";
            var code = windows.Code is { } number ? $"{ExceptionName(number)} (0x{number:X8})" : "A crash";
            lines.Add(crash is null ? $"- {code}{place}" : $"- Windows' report: {code}{place}");
        }
        if (crash is { Frames.Count: > 0 })
        {
            lines.AddRange(["", $"{crash.Where}:", "```"]);
            lines.AddRange(crash.Frames);
            lines.Add("```");
        }
        lines.AddRange(["", $"<sub>From {Path.GetFileName(file)}.</sub>"]);
        // An access violation's address is a detail, for the issue rather than its title.
        return new Report(file, date, $"Crash: {FaultAddress().Replace(kind, "")} in Reqly {version}", string.Join('\n', lines));
    }

    /// <summary>A Windows exception code's name, such as Access violation for 0xC0000005.</summary>
    private static string ExceptionName(uint code) => code switch
    {
        0xC0000005 => "Access violation",
        // How Swift stops when a check fails.
        0xC000001D => "Illegal instruction",
        0xC0000409 => "Fail fast",
        0xC00000FD => "Stack overflow",
        0xC0000374 => "Heap corruption",
        // An error WinUI reports from the app it runs.
        0xC000027B => "WinUI error",
        0xE0434352 => ".NET exception",
        0x80000003 => "Breakpoint",
        // .NET's errors, as WinUI hands them on to Windows, by their codes.
        0x80131509 => "InvalidOperationException",
        0x80004003 => "NullReferenceException",
        0x80070057 => "ArgumentException",
        0x80131502 => "ArgumentOutOfRangeException",
        0x80131508 => "IndexOutOfRangeException",
        0x80004002 => "InvalidCastException",
        0x80131515 => "NotSupportedException",
        0x80004001 => "NotImplementedException",
        0x80131537 => "FormatException",
        0x80131577 => "KeyNotFoundException",
        0x80131622 => "ObjectDisposedException",
        0x8013153B => "OperationCanceledException",
        0x80131620 => "IOException",
        0x80070005 => "UnauthorizedAccessException",
        _ => $"Exception 0x{code:X8}",
    };

    /// <summary>Windows' name, version and build, and the processor, such as Windows 11 26H2 (build 26300.9711), x64.</summary>
    public static string WindowsVersion
    {
        get
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion");
            var build = key?.GetValue("CurrentBuild") as string ?? Environment.OSVersion.Version.Build.ToString(CultureInfo.InvariantCulture);
            var update = key?.GetValue("UBR") is int ubr ? $".{ubr}" : "";
            var release = key?.GetValue("DisplayVersion") is string display ? $" {display}" : "";
            // The registry still names Windows 11 Windows 10, so its build tells them apart.
            var name = int.TryParse(build, out var number) && number >= 22000 ? "Windows 11" : "Windows 10";
            return $"{name}{release} (build {build}{update}), {RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant()}";
        }
    }

    /// <summary>The text without your user folder's path, and anyone else's.</summary>
    private static string Sanitized(string text)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (home.Length > 3)
        {
            text = text.Replace(home, "%USERPROFILE%", StringComparison.OrdinalIgnoreCase);
        }
        return UserFolder().Replace(text, @"$1\Users\…");
    }

    [GeneratedRegex(@"([A-Za-z]:)\\Users\\[^\\\s""]+", RegexOptions.IgnoreCase)]
    private static partial Regex UserFolder();

    // MARK: What a run wrote

    /// <summary>How a run stopped, from its file: Swift's error and the crashed thread's stack, or .NET's error.</summary>
    private sealed record Crash(string Kind, string? Module, IReadOnlyList<string> Messages, string Where, IReadOnlyList<string> Frames)
    {
        public static Crash? Read(string text, string program)
        {
            var lines = text.ReplaceLineEndings("\n").Split('\n');
            return FromDotNet(lines) ?? FromSwift(lines, program);
        }

        /// <summary>An error that .NET or WinUI stopped Reqly with, as <see cref="CrashLog.Stopped"/> wrote it.</summary>
        private static Crash? FromDotNet(string[] lines)
        {
            var start = Array.IndexOf(lines, CrashLog.StoppedInDotNet);
            if (start < 0)
            {
                return null;
            }
            var messages = new List<string>();
            var at = start + 1;
            if (at < lines.Length && lines[at].StartsWith("WinUI: ", StringComparison.Ordinal))
            {
                messages.Add(Sanitized(lines[at]));
                at += 1;
            }
            if (at >= lines.Length)
            {
                return null;
            }
            // Such as System.InvalidOperationException: what went wrong.
            var first = lines[at];
            var colon = first.IndexOf(": ", StringComparison.Ordinal);
            var type = colon > 0 ? first[..colon] : first.Trim();
            if (colon > 0)
            {
                messages.Insert(0, Sanitized(first[(colon + 2)..].Trim()));
            }
            var frames = new List<string>();
            for (var i = at + 1; i < lines.Length && lines[i].Length > 0; i++)
            {
                var line = lines[i].Trim();
                if (line.StartsWith("at ", StringComparison.Ordinal))
                {
                    // Not .NET's passing the error on, or Reqly's noting it.
                    if (!line.Contains("<ThrowAsync>", StringComparison.Ordinal) && !line.Contains("Reqly.CrashReports.", StringComparison.Ordinal))
                    {
                        frames.Add(SourceFile().Replace(Sanitized(line), " in $1"));
                    }
                }
                else if (line.StartsWith("--->", StringComparison.Ordinal))
                {
                    frames.Add(Sanitized(line));
                }
                else if (frames.Count == 0)
                {
                    // The rest of a message that has more than one line.
                    messages.Add(Sanitized(line));
                }
            }
            return new Crash(type, null, messages, "Where it happened", Limited(frames));
        }

        /// <summary>
        /// Swift's error, if it gave one, and the crashed thread's stack, which the core writes as
        /// Swift's backtracer does (see CCrashStack): each frame as the function and the line, when
        /// <see cref="Symbols"/> can tell, and otherwise as the offset in its module, to look up
        /// with that version's debug information.
        /// </summary>
        private static Crash? FromSwift(string[] lines, string program)
        {
            var messages = lines.Where(line => line.Contains("Fatal error", StringComparison.Ordinal)).Select(line => Sanitized(line.Trim())).Distinct().ToList();
            var reason = lines.Select(line => ProgramCrashed().Match(line)).FirstOrDefault(match => match.Success)?.Groups[1].Value;
            if (messages.Count == 0 && reason is null)
            {
                return null;
            }
            var images = lines.Select(line => Image().Match(line)).Where(match => match.Success)
                .Select(match => new Symbols.Image(
                    ulong.Parse(match.Groups["start"].Value, NumberStyles.HexNumber), ulong.Parse(match.Groups["end"].Value, NumberStyles.HexNumber),
                    match.Groups["name"].Value, match.Groups["build"].Value, match.Groups["path"].Value.Trim()))
                .ToList();
            var frames = new List<Symbols.Frame>();
            string? where = null;
            var crashed = Array.FindIndex(lines, line => CrashedThread().IsMatch(line));
            if (crashed >= 0)
            {
                where = lines[crashed].TrimEnd(':');
                // A blank line comes before the frames, and another after them.
                var first = crashed + 1;
                while (first < lines.Length && lines[first].Trim().Length == 0)
                {
                    first += 1;
                }
                for (var i = first; i < lines.Length && lines[i].Trim().Length > 0; i++)
                {
                    if (Frame(lines[i], images) is { } frame)
                    {
                        frames.Add(frame);
                    }
                }
            }
            var named = Symbols.Look(frames, Path.GetDirectoryName(program));
            var dotNet = new Queue<List<string>>(DotNetFrames(lines));
            var shown = new List<string>();
            for (var i = 0; i < frames.Count; i++)
            {
                var frame = frames[i];
                if (named.TryGetValue(frame, out var functions))
                {
                    shown.AddRange(functions.Select((function, index) => $"{frame.Number}  {frame.Module}  {(index < functions.Count - 1 ? "[inlined] " : "")}{function}"));
                    continue;
                }
                if (frame.Module is not null)
                {
                    shown.Add($"{frame.Number}  {frame.Module}  {frame.Symbol}");
                    continue;
                }
                // Code in no module, such as .NET's, which it compiles as it runs, says nothing by its
                // address alone. .NET named its frames as Reqly crashed, a group for each stretch of them.
                var last = i;
                while (last + 1 < frames.Count && frames[last + 1].Module is null)
                {
                    last += 1;
                }
                var numbers = last > i ? $"{frame.Number}–{frames[last].Number}" : frame.Number;
                if (dotNet.TryDequeue(out var group))
                {
                    shown.Add($"{numbers}  .NET:");
                    shown.AddRange(group.Select(line => $"      {line}"));
                }
                else
                {
                    shown.Add(last > i ? $"{numbers}  ?  {last - i + 1} frames in no module, as .NET's own code is" : $"{numbers}  ?  {frame.Symbol}");
                }
                i = last;
            }
            // Further down than the frames the core wrote.
            while (dotNet.TryDequeue(out var group))
            {
                shown.Add("…  .NET:");
                shown.AddRange(group.Select(line => $"      {line}"));
            }
            // Swift's message, when it gave one, says what failed; how its check stopped Reqly is a detail.
            var kind = messages.Count > 0 ? "Fatal error" : reason ?? "Fatal error";
            if (messages.Count > 0 && reason is not null)
            {
                messages.Add($"{reason}{(frames.FirstOrDefault()?.Module is { } module ? $" in {module}" : "")}");
            }
            return new Crash(kind, messages.Count > 0 ? null : frames.FirstOrDefault()?.Module, messages, where ?? "The crashed thread", Limited(shown));
        }

        /// <summary>
        /// .NET's frames of the crashed thread, as <see cref="CrashLog.WriteDotNetFrames"/> wrote
        /// them: a group for each stretch of them, which native code called, without Reqly's own
        /// noting of errors.
        /// </summary>
        private static List<List<string>> DotNetFrames(string[] lines)
        {
            var groups = new List<List<string>>();
            var start = Array.IndexOf(lines, CrashLog.DotNetFrames);
            if (start < 0)
            {
                return groups;
            }
            var group = new List<string>();
            for (var i = start + 1; i < lines.Length && lines[i].Trim().Length > 0; i++)
            {
                var line = lines[i].Trim();
                if (line == CrashLog.CalledFromNative)
                {
                    if (group.Count > 0)
                    {
                        groups.Add(group);
                        group = [];
                    }
                }
                else if (line.StartsWith("at ", StringComparison.Ordinal) && !line.Contains("Reqly.CrashReports.", StringComparison.Ordinal))
                {
                    // A call into native code can show twice, as itself and as the stub .NET makes for it.
                    var frame = SourceFile().Replace(Sanitized(line), " in $1");
                    if (group.Count == 0 || group[^1] != frame)
                    {
                        group.Add(frame);
                    }
                }
            }
            if (group.Count > 0)
            {
                groups.Add(group);
            }
            return groups;
        }

        /// <summary>
        /// A frame of the stack, such as <c>2 [ra] 0x00007ff6… &lt;unknown&gt; in ReqlyCore.dll</c>: its
        /// module, and without a symbol, its offset in the module, such as <c>+0x1a2b3c</c>.
        /// </summary>
        private static Symbols.Frame? Frame(string line, List<Symbols.Image> images)
        {
            var match = FrameLine().Match(line);
            if (!match.Success)
            {
                return null;
            }
            var address = ulong.Parse(match.Groups["address"].Value, NumberStyles.HexNumber);
            var rest = match.Groups["rest"].Value;
            string? place = null;
            var at = rest.LastIndexOf(" at ", StringComparison.Ordinal);
            if (at > 0)
            {
                place = Path.GetFileName(rest[(at + 4)..].Trim());
                rest = rest[..at];
            }
            var inModule = rest.LastIndexOf(" in ", StringComparison.Ordinal);
            var module = inModule >= 0 ? rest[(inModule + 4)..].Trim() : null;
            var symbol = (inModule >= 0 ? rest[..inModule] : rest).Trim();
            var image = images.FirstOrDefault(image => address >= image.Start && address < image.End);
            if (symbol.Length == 0 || symbol == "<unknown>")
            {
                symbol = image is not null ? $"+0x{address - image.Start:x}" : $"0x{address:x}";
            }
            return new Symbols.Frame(
                match.Groups["number"].Value, module, $"{Sanitized(symbol)}{(place is null ? "" : $" at {place}")}", address,
                IsReturn: match.Groups["kind"].Value == "ra", image);
        }

        private static IReadOnlyList<string> Limited(List<string> frames) =>
            frames.Count > FramesShown ? [.. frames.Take(FramesShown), $"… {frames.Count - FramesShown} more"] : frames;
    }

    [GeneratedRegex(@"^\*\*\* Program crashed: (.+?) at 0x[0-9a-fA-F]+ \*\*\*$")]
    private static partial Regex ProgramCrashed();

    [GeneratedRegex(@" (?:reading|writing|running) 0x[0-9a-fA-F]+$")]
    private static partial Regex FaultAddress();

    [GeneratedRegex(@"^Thread \d+.* crashed:$")]
    private static partial Regex CrashedThread();

    [GeneratedRegex(@"^(?<number>\d+)\s+(?:\[(?<kind>[^\]]+)\]\s+)?0x(?<address>[0-9a-fA-F]+)\s+(?<rest>.+)$")]
    private static partial Regex FrameLine();

    /// <summary>A module the stack went through: where it was, its build's ID or time stamp, its name and its file.</summary>
    [GeneratedRegex(@"^0x(?<start>[0-9a-fA-F]+)\S*?0x(?<end>[0-9a-fA-F]+)\s+(?<build><no build ID>|[0-9a-fA-F]+)\s+(?<name>\S+)\s+(?<path>.+)$")]
    private static partial Regex Image();

    /// <summary>A .NET frame's source file, without the folders it was built in.</summary>
    [GeneratedRegex(@" in (?:.*[\\/])?([^\\/]+:line \d+)$")]
    private static partial Regex SourceFile();

    // MARK: The runs' files

    private sealed record Run(string Path, string Version, DateTime Started, DateTime Ended, string Text);

    /// <summary>The files this Reqly's runs left, but not the running ones'.</summary>
    private static List<Run> Runs(string folder, string program)
    {
        var runs = new List<Run>();
        if (!Directory.Exists(folder))
        {
            return runs;
        }
        foreach (var path in Directory.EnumerateFiles(folder, $"{CrashLog.Prefix}*.txt"))
        {
            if (string.Equals(path, CrashLog.FilePath, StringComparison.OrdinalIgnoreCase) || IsRunning(path, program))
            {
                continue;
            }
            try
            {
                string text;
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var reader = new StreamReader(stream, Encoding.UTF8))
                {
                    var buffer = new char[1 << 20];
                    text = new string(buffer, 0, reader.ReadBlock(buffer, 0, buffer.Length));
                }
                // Reqly <version>, then the program, then Started <time>.
                var head = text.ReplaceLineEndings("\n").Split('\n', 4);
                if (head.Length < 3 || !string.Equals(head[1].Trim(), program, StringComparison.OrdinalIgnoreCase))
                {
                    // Another copy of Reqly's, such as a test build's.
                    continue;
                }
                var version = head[0].StartsWith("Reqly ", StringComparison.Ordinal) ? head[0][6..].Trim() : Help.AppInfo.Version;
                var started = head[2].StartsWith("Started ", StringComparison.Ordinal)
                    && DateTime.TryParse(head[2][8..].Trim(), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var time)
                    ? time.ToUniversalTime() : File.GetCreationTimeUtc(path);
                runs.Add(new Run(path, version, started, File.GetLastWriteTimeUtc(path), text));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                AppLog.Write($"couldn't read {Path.GetFileName(path)}: {error.Message}");
            }
        }
        return runs;
    }

    /// <summary>Whether the run that a file is named after still runs, as this program.</summary>
    private static bool IsRunning(string path, string program)
    {
        var name = Path.GetFileNameWithoutExtension(path);
        if (!int.TryParse(name[(name.LastIndexOf('-') + 1)..], out var id))
        {
            return false;
        }
        try
        {
            using var process = Process.GetProcessById(id);
            return string.Equals(process.MainModule?.FileName, program, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return false;
        }
    }

    /// <summary>Renames a crashed run's file, so it's offered once and kept to attach to an issue.</summary>
    private static string Keep(string path, DateTime date)
    {
        var kept = Path.Combine(Path.GetDirectoryName(path)!, $"{Offered}{date.ToLocalTime():yyyyMMdd-HHmmss}.txt");
        try
        {
            if (File.Exists(kept))
            {
                kept = Path.Combine(Path.GetDirectoryName(path)!, $"{Offered}{date.ToLocalTime():yyyyMMdd-HHmmss}-{Guid.NewGuid():N}.txt");
            }
            File.Move(path, kept);
            return kept;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            AppLog.Write($"couldn't keep {Path.GetFileName(path)}: {error.Message}");
            return path;
        }
    }

    /// <summary>Keeps only the newest crashes' files.</summary>
    private static void Prune(string folder)
    {
        foreach (var old in new DirectoryInfo(folder).EnumerateFiles($"{Offered}*.txt").OrderByDescending(file => file.LastWriteTimeUtc).Skip(OfferedKept))
        {
            TryDelete(old.FullName);
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            AppLog.Write($"couldn't delete {Path.GetFileName(path)}: {error.Message}");
        }
    }

    // MARK: Windows' reports

    private sealed record WindowsReport(string File, DateTime Time, string? AppVersion, string? Module, string? ModuleVersion, uint? Code, string? Offset);

    /// <summary>
    /// The crashes of this Reqly that Windows Error Reporting keeps a report of, which say in
    /// which module it stopped and why, but nothing of what it was doing.
    /// </summary>
    private static List<WindowsReport> WindowsReports(string program)
    {
        var reports = new List<WindowsReport>();
        var places = new[] { Environment.SpecialFolder.CommonApplicationData, Environment.SpecialFolder.LocalApplicationData }
            .SelectMany(root => new[] { "ReportArchive", "ReportQueue" }
                .Select(kind => Path.Combine(Environment.GetFolderPath(root), "Microsoft", "Windows", "WER", kind)));
        foreach (var place in places.Where(Directory.Exists))
        {
            IEnumerable<string> folders;
            try
            {
                folders = Directory.EnumerateDirectories(place, $"AppCrash_{Path.GetFileName(program)}_*").ToList();
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                continue;
            }
            foreach (var folder in folders)
            {
                if (WindowsReportIn(Path.Combine(folder, "Report.wer"), program) is { } report)
                {
                    reports.Add(report);
                }
            }
        }
        return reports;
    }

    private static WindowsReport? WindowsReportIn(string file, string program)
    {
        try
        {
            if (!File.Exists(file))
            {
                return null;
            }
            var values = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var line in File.ReadAllLines(file, Encoding.Unicode))
            {
                var equals = line.IndexOf('=');
                if (equals > 0)
                {
                    values[line[..equals]] = line[(equals + 1)..];
                }
            }
            if (!values.TryGetValue("AppPath", out var path) || !string.Equals(path, program, StringComparison.OrdinalIgnoreCase)
                || !values.TryGetValue("EventTime", out var time) || !long.TryParse(time, out var ticks))
            {
                return null;
            }
            // Sig[n].Name says what Sig[n].Value is.
            string? Value(string name) => values.FirstOrDefault(pair => pair.Key.EndsWith(".Name", StringComparison.Ordinal) && pair.Value == name) is { Key: { } key }
                && values.TryGetValue(key[..^5] + ".Value", out var value) ? value : null;
            var code = Value("Exception Code") is { } hex && uint.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var number) ? number : (uint?)null;
            var offset = Value("Exception Offset") is { } at && ulong.TryParse(at, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var place) ? $"0x{place:x}" : null;
            return new WindowsReport(file, DateTime.FromFileTimeUtc(ticks), Value("Application Version"), Value("Fault Module Name"), Value("Fault Module Version"), code, offset);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            AppLog.Write($"couldn't read Windows' report {file}: {error.Message}");
            return null;
        }
    }

    /// <summary>
    /// The version of Reqly that crashed, from Windows' report, which has only the four numbers of
    /// the file's version. When they're this Reqly's, it's this version, beta and all.
    /// </summary>
    private static string VersionOf(WindowsReport report)
    {
        var current = Environment.ProcessPath is { } program ? FileVersionInfo.GetVersionInfo(program).FileVersion : null;
        return report.AppVersion is null || report.AppVersion == current ? Help.AppInfo.Version : report.AppVersion;
    }
}
