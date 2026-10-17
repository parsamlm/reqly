using System.Security.Cryptography;
using System.Text;

namespace Reqly.Help;

/// <summary>
/// The software from Microsoft that comes with Reqly for Windows under Microsoft's own terms,
/// which ask that people who get it agree to them. Reqly asks once, the first time it opens, and
/// again when the terms change. <c>Assets\Terms\README.md</c> says where each text comes from.
/// </summary>
public static class Terms
{
    /// <summary>Some of Microsoft's software in Reqly: what it is, and its terms, in a file Reqly carries or on Microsoft's site.</summary>
    public sealed record Part(string Name, string Use, string? File, Uri? Page);

    public static readonly Part[] Parts =
    [
        new("the Windows App SDK", "which draws Reqly's windows", "WindowsAppSDK.txt", null),
        new("the Windows SDK", "whose interface for .NET Reqly uses", "WindowsSDK.txt", null),
        new("the Visual C++ runtime", "which Swift's runtime uses", null, new Uri("https://visualstudio.microsoft.com/license-terms/vs2022-cruntime/")),
    ];

    /// <summary>A part's terms, as Reqly carries them, if it does.</summary>
    public static string? Text(Part part)
    {
        if (part.File is null)
        {
            return null;
        }
        try
        {
            return File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Assets", "Terms", part.File));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            AppLog.Write($"couldn't read {part.File}: {error.Message}");
            return null;
        }
    }

    /// <summary>What the terms say, in short, so the agreement can tell when they change.</summary>
    public static string Version
    {
        get
        {
            var all = new StringBuilder();
            foreach (var part in Parts)
            {
                all.Append(part.Name).Append('\n').Append(part.Page?.ToString() ?? Text(part) ?? "").Append('\n');
            }
            return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(all.ToString())))[..16];
        }
    }
}
