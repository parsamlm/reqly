using System.Text.Json;
using System.Text.Json.Nodes;
using Reqly.Core;

namespace Reqly.Devices;

/// <summary>
/// Phones and tablets on the network: whether they may connect at all, the ones you let in, and
/// the ones waiting for you to decide. The core keeps the devices you let in, and the names you
/// give devices of every kind, in the same file the Mac keeps them in.
/// </summary>
public sealed class DevicesModel(CoreSession session)
{
    public WireDevices Devices { get; private set; } = WireDevices.None;

    /// <summary>A device waits for you to decide, or the devices changed.</summary>
    public event Action? Changed;

    public Task OpenAsync(string file, bool allowsNetworkDevices) =>
        ChangeAsync(new JsonObject { ["call"] = "openDevices", ["path"] = file, ["allowsNetworkDevices"] = allowsNetworkDevices });

    /// <summary>Reads the devices again, with this PC's addresses as they are now.</summary>
    public Task RefreshAsync() => ChangeAsync(new JsonObject { ["call"] = "devices" });

    /// <summary>Lets devices on the network connect, or only this PC. Turning it off turns away the ones waiting.</summary>
    public Task SetAllowsNetworkDevicesAsync(bool allows) =>
        ChangeAsync(new JsonObject { ["call"] = "setAllowsNetworkDevices", ["isOn"] = allows });

    /// <summary>Lets a device in, with the name you gave it, or turns it away until Reqly quits.</summary>
    public Task DecideAsync(string id, bool allow, string? name = null)
    {
        var call = new JsonObject { ["call"] = "decideDevice", ["device"] = id, ["allow"] = allow };
        if (name is not null)
        {
            call["name"] = name;
        }
        return ChangeAsync(call);
    }

    public Task ForgetAsync(string id) => ChangeAsync(new JsonObject { ["call"] = "forgetDevice", ["device"] = id });

    /// <summary>Names a device's traffic, from now on and in the list already.</summary>
    public Task RenameAsync(string id, string name) =>
        ChangeAsync(new JsonObject { ["call"] = "renameDevice", ["device"] = id, ["name"] = name });

    /// <summary>A QR code for an address, as rows of dark and light modules.</summary>
    public async Task<bool[][]?> QRCodeAsync(string text)
    {
        try
        {
            var result = await session.CallAsync(new JsonObject { ["call"] = "qrCode", ["text"] = text });
            return [.. result.GetProperty("rows").EnumerateArray().Select(row => row.GetString()!.Select(module => module == '1').ToArray())];
        }
        catch (CoreProblem problem)
        {
            AppLog.Write($"couldn't make a QR code: {problem.Message}");
            return null;
        }
    }

    /// <summary>A device asked to connect, as the core's "deviceWaiting" event says.</summary>
    public Task DeviceWaitingAsync() => RefreshAsync();

    private async Task ChangeAsync(JsonObject call)
    {
        try
        {
            Devices = Wire.Read<WireDevices>(await session.CallAsync(call));
        }
        catch (CoreProblem problem)
        {
            AppLog.Write($"couldn't change the devices ({call["call"]}): {problem.Message}");
            return;
        }
        Changed?.Invoke();
    }
}
