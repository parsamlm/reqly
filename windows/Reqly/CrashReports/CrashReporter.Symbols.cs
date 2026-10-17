using System.Diagnostics;
using System.Globalization;
using System.Text.Json;

namespace Reqly.CrashReports;

internal static partial class CrashReporter
{
    /// <summary>
    /// The function and line of each frame of the crashed thread's stack, from the debug
    /// information in the modules the crashed run had beside it, when they still have it and
    /// llvm-symbolizer, which comes with Swift's toolchain, is on this PC: as with a build of your
    /// own. A released Reqly's modules have none, so its report gives offsets, which
    /// <c>windows\scripts\symbolicate.ps1</c> looks up with that version's debug information.
    /// </summary>
    private static class Symbols
    {
        /// <summary>A module the stack went through: where it was, its build's time stamp, its name and its file.</summary>
        public sealed record Image(ulong Start, ulong End, string Name, string Build, string Path);

        /// <param name="IsReturn">Whether it's where a call returns to, as every frame after the first is.</param>
        public sealed record Frame(string Number, string? Module, string Symbol, ulong Address, bool IsReturn, Image? Image);

        /// <summary>
        /// The functions of the frames it can tell, as "name at File.swift:12", innermost first: the
        /// inlined ones, then the one they're in. Swift's names are made short, as Swift's
        /// backtracer makes them, by swift-demangle, which comes with llvm-symbolizer.
        /// </summary>
        public static Dictionary<Frame, List<string>> Look(IReadOnlyList<Frame> frames, string? folder)
        {
            var named = new Dictionary<Frame, List<string>>();
            if (folder is null || frames.Count == 0 || Symbolizer() is not { } symbolizer)
            {
                return named;
            }
            var found = new Dictionary<Frame, List<(string Function, string Place)>>();
            foreach (var module in frames.Where(frame => frame.Image is not null).GroupBy(frame => frame.Image!))
            {
                var image = module.Key;
                if (!string.Equals(Path.GetDirectoryName(image.Path), folder, StringComparison.OrdinalIgnoreCase) || !IsBuild(image))
                {
                    continue;
                }
                // A return address is just past its call, which can be the next line's.
                var offsets = module.ToDictionary(frame => frame, frame => frame.Address - image.Start - (frame.IsReturn ? 1UL : 0UL));
                var places = Run(symbolizer, image.Path, offsets.Values.Distinct().ToList());
                foreach (var (frame, offset) in offsets)
                {
                    if (places.TryGetValue(offset, out var functions) && functions.Count > 0)
                    {
                        found[frame] = functions;
                    }
                }
            }
            var names = Demangled(Path.Combine(Path.GetDirectoryName(symbolizer)!, "swift-demangle.exe"),
                found.Values.SelectMany(functions => functions.Select(function => function.Function)).Distinct().ToList());
            foreach (var (frame, functions) in found)
            {
                named[frame] = functions.Select(function => names.GetValueOrDefault(function.Function, function.Function) is { Length: > 0 } name
                    ? $"{name} at {function.Place}"
                    : $"at {function.Place}").ToList();
            }
            return named;
        }

        /// <summary>
        /// Swift's names, made short, such as <c>closure #2 in reqlyCrashForTest(_:)</c>; other
        /// names stay as they are. Without swift-demangle, Swift's are left out.
        /// </summary>
        private static Dictionary<string, string> Demangled(string demangler, List<string> names)
        {
            var swift = names.Where(name => name.StartsWith("$s", StringComparison.Ordinal)).ToList();
            var shown = swift.ToDictionary(name => name, _ => "");
            if (swift.Count == 0 || !File.Exists(demangler))
            {
                return shown;
            }
            var output = Output(demangler, ["--simplified", "--compact"], swift);
            for (var i = 0; i < swift.Count && i < output.Count; i++)
            {
                shown[swift[i]] = output[i];
            }
            return shown;
        }

        /// <summary>Whether the module's file is still the build that crashed, by the time stamp the linker gave it.</summary>
        private static bool IsBuild(Image image)
        {
            try
            {
                using var file = File.OpenRead(image.Path);
                using var reader = new BinaryReader(file);
                file.Position = 0x3C;
                file.Position = reader.ReadInt32() + 8;
                return reader.ReadUInt32().ToString("x8", CultureInfo.InvariantCulture).Equals(image.Build, StringComparison.OrdinalIgnoreCase);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
            {
                return false;
            }
        }

        /// <summary>llvm-symbolizer: on the PATH, or where Swift's installer puts its toolchains.</summary>
        private static string? Symbolizer()
        {
            const string Name = "llvm-symbolizer.exe";
            foreach (var folder in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            {
                try
                {
                    var candidate = Path.Combine(folder.Trim().Trim('"'), Name);
                    if (File.Exists(candidate))
                    {
                        return candidate;
                    }
                }
                catch (ArgumentException)
                {
                    // Not a folder's path.
                }
            }
            var toolchains = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Swift", "Toolchains");
            return Directory.Exists(toolchains)
                ? Directory.EnumerateDirectories(toolchains).Select(toolchain => Path.Combine(toolchain, "usr", "bin", Name)).FirstOrDefault(File.Exists)
                : null;
        }

        /// <summary>The functions at each offset in the module, with their files and lines, from llvm-symbolizer.</summary>
        private static Dictionary<ulong, List<(string Function, string Place)>> Run(string symbolizer, string module, List<ulong> offsets)
        {
            var found = new Dictionary<ulong, List<(string Function, string Place)>>();
            try
            {
                var lines = Output(symbolizer, [$"--obj={module}", "--relative-address", "--inlines", "--output-style=JSON"], offsets.Select(offset => $"0x{offset:x}"));
                foreach (var line in lines)
                {
                    using var answer = JsonDocument.Parse(line);
                    if (!answer.RootElement.TryGetProperty("Address", out var address) || !answer.RootElement.TryGetProperty("Symbol", out var symbols)
                        || !ulong.TryParse(address.GetString()?.Replace("0x", "", StringComparison.Ordinal), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var at))
                    {
                        continue;
                    }
                    var functions = new List<(string Function, string Place)>();
                    foreach (var symbol in symbols.EnumerateArray())
                    {
                        var function = symbol.TryGetProperty("FunctionName", out var name) ? name.GetString() ?? "" : "";
                        var file = symbol.TryGetProperty("FileName", out var path) ? path.GetString() : null;
                        var number = symbol.TryGetProperty("Line", out var lineNumber) && lineNumber.TryGetInt32(out var value) ? value : 0;
                        // Without its file and line, a name is only the nearest one the module exports, which may be another function's.
                        if (string.IsNullOrEmpty(file) || number == 0)
                        {
                            continue;
                        }
                        functions.Add((function == "??" ? "" : function, $"{Path.GetFileName(file)}:{number}"));
                    }
                    found[at] = functions;
                }
            }
            catch (JsonException error)
            {
                AppLog.Write($"couldn't read the crash's debug information: {error.Message}");
            }
            return found;
        }

        /// <summary>What a tool writes, a line for each line it's given, or nothing if it fails.</summary>
        private static List<string> Output(string tool, IEnumerable<string> arguments, IEnumerable<string> input)
        {
            var start = new ProcessStartInfo(tool)
            {
                RedirectStandardInput = true,
                // Not to this run's own crash log, which has the standard error.
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            foreach (var argument in arguments)
            {
                start.ArgumentList.Add(argument);
            }
            try
            {
                using var process = Process.Start(start);
                if (process is null)
                {
                    return [];
                }
                var output = process.StandardOutput.ReadToEndAsync();
                _ = process.StandardError.ReadToEndAsync();
                foreach (var line in input)
                {
                    process.StandardInput.WriteLine(line);
                }
                process.StandardInput.Close();
                if (!process.WaitForExit(20_000))
                {
                    process.Kill();
                    return [];
                }
                return [.. output.Result.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)];
            }
            catch (Exception error) when (error is System.ComponentModel.Win32Exception or IOException or InvalidOperationException)
            {
                AppLog.Write($"couldn't run {Path.GetFileName(tool)} for the crash's debug information: {error.Message}");
                return [];
            }
        }
    }
}
