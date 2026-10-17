using System.Reflection;
using System.Text.Json;

namespace Reqly.Help;

/// <summary>
/// What Reqly tells about itself, as on the Mac: its version, where to learn more, its license,
/// and the open-source code it includes.
/// </summary>
public static class AppInfo
{
    public static readonly Uri Website = new("https://reqly.net");
    public static readonly Uri SourceCode = new("https://github.com/parsamlm/reqly");

    /// <summary>Reqly's version, such as 1.0.0, as About shows it and HAR files name their creator.</summary>
    public static string Version =>
        typeof(App).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "1.0";

    public static string Copyright =>
        typeof(App).Assembly.GetCustomAttribute<AssemblyCopyrightAttribute>()?.Copyright ?? "Copyright © 2026 The Reqly Authors";

    /// <summary>The license's full text, as Reqly carries it.</summary>
    public static string? LicenseText => Read("LICENSE");

    /// <summary>
    /// The open-source packages inside Reqly, from <c>Assets\Acknowledgements.json</c>, which
    /// <c>tools/acknowledgements.py</c> writes. None if the file is missing.
    /// </summary>
    public static IReadOnlyList<OpenSourcePackage> OpenSourcePackages => packages.Value;

    private static readonly Lazy<IReadOnlyList<OpenSourcePackage>> packages = new(() =>
    {
        if (Read(Path.Combine("Assets", "Acknowledgements.json")) is not { } json)
        {
            return [];
        }
        try
        {
            return JsonSerializer.Deserialize<Acknowledgements>(json, new JsonSerializerOptions { PropertyNameCaseInsensitive = true })?.Packages ?? [];
        }
        catch (JsonException error)
        {
            AppLog.Write($"couldn't read the open-source licenses: {error.Message}");
            return [];
        }
    });

    private static string? Read(string name)
    {
        try
        {
            return File.ReadAllText(Path.Combine(AppContext.BaseDirectory, name));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private sealed record Acknowledgements(OpenSourcePackage[] Packages);
}

/// <summary>An open-source package whose code is inside Reqly, with its license and notices in full.</summary>
public sealed record OpenSourcePackage(string Name, string Version, string Url, string License, OpenSourceNotice[] Notices)
{
    /// <summary>What a screen reader says for it in the list.</summary>
    public string Spoken => $"{Name}, version {Version}";
}

/// <summary>
/// A license, or a notice that a license asks to keep with the code. The title is the file it
/// comes from, or the code it covers.
/// </summary>
public sealed record OpenSourceNotice(string Title, string Text);
