using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Reqly.Install;

/// <summary>
/// The files Reqly opens from File Explorer: saved sessions, which it opens when you open one,
/// and HAR files, which other apps open too, so Reqly is one choice under Open with. For your user
/// alone, as Reqly is installed.
/// </summary>
internal static partial class FileTypes
{
    private const string Classes = @"Software\Classes";
    private const string SessionType = "Reqly.Session";
    private const string HarType = "Reqly.Har";
    /// <summary>
    /// What <c>.reqly</c> pointed at before Reqly was installed, such as the type Open with makes
    /// when you choose an app for files no app had claimed. Uninstalling puts it back.
    /// </summary>
    private const string Replaced = "ReplacedDefault";

    /// <summary>Points saved sessions and HAR files at this Reqly, where its installer put it.</summary>
    public static void Register()
    {
        var program = Environment.ProcessPath!;
        using (var classes = Registry.CurrentUser.CreateSubKey(Classes))
        {
            Describe(classes, SessionType, "Reqly session", program);
            Describe(classes, HarType, "HAR file", program);
            using (var session = classes.CreateSubKey(".reqly"))
            {
                if (session.GetValue("") is string before && before != SessionType)
                {
                    using var type = classes.CreateSubKey(SessionType);
                    type.SetValue(Replaced, before);
                }
                session.SetValue("", SessionType);
                using var openWith = session.CreateSubKey("OpenWithProgids");
                openWith.SetValue(SessionType, Array.Empty<byte>(), RegistryValueKind.None);
            }
            using (var har = classes.CreateSubKey(@".har\OpenWithProgids"))
            {
                har.SetValue(HarType, Array.Empty<byte>(), RegistryValueKind.None);
            }
        }
        Changed();
    }

    /// <summary>
    /// Takes Reqly away from the file types again, leaving what other apps set, and puts back what
    /// <c>.reqly</c> pointed at before. Keys Reqly made that are left empty go too.
    /// </summary>
    public static void Remove()
    {
        using (var classes = Registry.CurrentUser.OpenSubKey(Classes, writable: true))
        {
            if (classes is null)
            {
                return;
            }
            string? replaced;
            using (var type = classes.OpenSubKey(SessionType))
            {
                replaced = type?.GetValue(Replaced) as string;
            }
            classes.DeleteSubKeyTree(SessionType, throwOnMissingSubKey: false);
            classes.DeleteSubKeyTree(HarType, throwOnMissingSubKey: false);
            using (var session = classes.OpenSubKey(".reqly", writable: true))
            {
                if (session?.GetValue("") as string == SessionType)
                {
                    if (replaced is null)
                    {
                        session.DeleteValue("");
                    }
                    else
                    {
                        session.SetValue("", replaced);
                    }
                }
            }
            Forget(classes, ".reqly", SessionType);
            Forget(classes, ".har", HarType);
        }
        Changed();
    }

    /// <summary>Takes Reqly's type off an extension's Open with list, then the extension's keys if that left them empty.</summary>
    private static void Forget(RegistryKey classes, string extension, string type)
    {
        using (var openWith = classes.OpenSubKey($@"{extension}\OpenWithProgids", writable: true))
        {
            openWith?.DeleteValue(type, throwOnMissingValue: false);
        }
        DeleteIfEmpty(classes, $@"{extension}\OpenWithProgids");
        DeleteIfEmpty(classes, extension);
    }

    private static void DeleteIfEmpty(RegistryKey classes, string name)
    {
        bool isEmpty;
        using (var key = classes.OpenSubKey(name))
        {
            isEmpty = key is { ValueCount: 0, SubKeyCount: 0 };
        }
        if (isEmpty)
        {
            classes.DeleteSubKey(name, throwOnMissingSubKey: false);
        }
    }

    private static void Describe(RegistryKey classes, string type, string name, string program)
    {
        using var key = classes.CreateSubKey(type);
        key.SetValue("", name);
        using (var icon = key.CreateSubKey("DefaultIcon"))
        {
            icon.SetValue("", $"\"{program}\",0");
        }
        using var command = key.CreateSubKey(@"shell\open\command");
        command.SetValue("", $"\"{program}\" \"%1\"");
    }

    /// <summary>Tells File Explorer the file types changed, so it shows their new icons and choices.</summary>
    private static void Changed() => SHChangeNotify(AssociationsChanged, IdList, IntPtr.Zero, IntPtr.Zero);

    private const int AssociationsChanged = 0x08000000;
    private const uint IdList = 0;

    [LibraryImport("shell32.dll")]
    private static partial void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);
}
