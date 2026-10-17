using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage;
using Windows.Storage.FileProperties;

namespace Reqly.Traffic;

/// <summary>Each app's icon, from its program, as File Explorer shows it. Each is made once, on the UI thread.</summary>
public static class AppIcons
{
    /// <summary>The icon's size in the list, before the display's scaling.</summary>
    private const uint Size = 16;

    private static readonly Dictionary<string, Task<ImageSource?>> Icons = new(StringComparer.OrdinalIgnoreCase);

    public static Task<ImageSource?> GetAsync(string program)
    {
        if (!Icons.TryGetValue(program, out var icon))
        {
            icon = LoadAsync(program);
            Icons[program] = icon;
        }
        return icon;
    }

    private static async Task<ImageSource?> LoadAsync(string program)
    {
        // A program of another computer's, such as a Mac's in a session saved there, isn't on this one.
        if (!Path.IsPathFullyQualified(program))
        {
            return null;
        }
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(program);
            using var thumbnail = await file.GetThumbnailAsync(ThumbnailMode.SingleItem, Size, ThumbnailOptions.UseCurrentScale);
            if (thumbnail is null)
            {
                return null;
            }
            var image = new BitmapImage();
            await image.SetSourceAsync(thumbnail);
            return image;
        }
        catch (Exception error)
        {
            // A program Reqly can't read, such as one of Windows' own, shows no icon.
            AppLog.Write($"no icon for {program}: {error.Message}");
            return null;
        }
    }
}
