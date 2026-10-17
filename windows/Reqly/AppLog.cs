namespace Reqly;

/// <summary>
/// What Reqly did and why anything failed, with times, in a file on this computer. Nothing in it
/// is sent anywhere. It starts over once it passes a megabyte.
/// </summary>
public static class AppLog
{
    private const long Limit = 1 << 20;
    private static string? file;
    private static readonly Lock Writing = new();

    public static void Open(string path)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            if (File.Exists(path) && new FileInfo(path).Length > Limit)
            {
                File.Delete(path);
            }
            file = path;
            Write($"Reqly started: {Environment.ProcessPath}");
        }
        catch (IOException)
        {
            file = null;
        }
    }

    public static void Write(string line)
    {
        if (file is null)
        {
            return;
        }
        lock (Writing)
        {
            try
            {
                File.AppendAllText(file, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {line}{Environment.NewLine}");
            }
            catch (IOException)
            {
                // A log that can't be written mustn't stop Reqly.
            }
        }
    }
}
