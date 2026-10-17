using System.Runtime.InteropServices;

namespace Reqly;

/// <summary>
/// Whether Windows may slow Reqly down while its windows are behind others, as it does to save
/// power. While Reqly captures, it may not: Reqly passes other apps' traffic on as it comes, and
/// with Windows' power saving, downloads through it went about a third slower and its window
/// answered later.
/// </summary>
internal static partial class WindowsPower
{
    private const int ProcessPowerThrottling = 4;
    private const uint ExecutionSpeed = 1;

    /// <summary>Asks Windows not to slow Reqly down, or lets Windows decide again.</summary>
    public static void KeepFullSpeed(bool keeps)
    {
        // Taking charge of execution speed with its throttling off, or handing it back.
        var state = new PowerThrottlingState { Version = 1, ControlMask = keeps ? ExecutionSpeed : 0, StateMask = 0 };
        if (!SetProcessInformation(GetCurrentProcess(), ProcessPowerThrottling, ref state, (uint)Marshal.SizeOf<PowerThrottlingState>()))
        {
            AppLog.Write($"couldn't change Windows' power saving for Reqly: error {Marshal.GetLastPInvokeError()}");
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PowerThrottlingState
    {
        public uint Version;
        public uint ControlMask;
        public uint StateMask;
    }

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetProcessInformation(IntPtr process, int informationClass, ref PowerThrottlingState information, uint size);

    [LibraryImport("kernel32.dll")]
    private static partial IntPtr GetCurrentProcess();
}
