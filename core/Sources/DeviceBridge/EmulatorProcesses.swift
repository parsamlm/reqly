import Foundation
import ReqlyModel

/// Tells the processes of Android emulators apart from the computer's own programs, on the Mac and
/// on Windows, so their traffic goes to the emulator, as a device.
public enum EmulatorProcesses {
    /// The emulator a process works for, or `nil` for the computer's own programs.
    /// - Parameters:
    ///   - path: The process's program.
    ///   - arguments: The process's arguments. They're read only for an emulator.
    ///   - emulators: The arguments of each Android emulator that's running. They're read only for
    ///     netsimd.
    public static func device(
        ofProgram path: String, arguments: () -> [String]?, emulators: () -> [[String]]
    ) -> Device? {
        if isEmulator(path) {
            return emulator(named: arguments().flatMap(virtualDevice(in:)))
        }
        if isEmulatorWiFi(path) {
            // One netsimd serves every emulator that's running: the first one starts it, and
            // the others share it. So its traffic is credited to an emulator by name only while
            // just one is running.
            let names = Set(emulators().compactMap(virtualDevice(in:)))
            return emulator(named: names.count == 1 ? names.first : nil)
        }
        return nil
    }

    /// The emulator's program, such as `…/emulator/qemu/darwin-aarch64/qemu-system-aarch64`, or
    /// `…\emulator\qemu\windows-x86_64\qemu-system-x86_64.exe` on Windows.
    public static func isEmulator(_ path: String) -> Bool {
        programName(path).hasPrefix("qemu-system-") || folders(path).contains("/emulator/qemu/")
    }

    /// The emulators' netsimd, such as `…/sdk/emulator/netsimd`. It carries their Wi-Fi, which
    /// is the network Android uses first.
    public static func isEmulatorWiFi(_ path: String) -> Bool {
        programName(path) == "netsimd"
    }

    /// An emulator running the virtual device `name`, or any emulator when that's not known.
    public static func emulator(named name: String?) -> Device {
        Device(
            id: "emulator:\(name ?? "Android Emulator")", kind: .emulator,
            name: name.map(readableName) ?? "Android Emulator")
    }

    /// The virtual device the emulator runs, from `-avd Pixel_10` or `@Pixel_10`.
    public static func virtualDevice(in arguments: [String]) -> String? {
        if let index = arguments.firstIndex(of: "-avd"), arguments.indices.contains(index + 1) {
            return arguments[index + 1]
        }
        return arguments.first { $0.hasPrefix("@") && $0.count > 1 }.map { String($0.dropFirst()) }
    }

    /// Such as "Pixel 10 Pro XL" for `Pixel_10_Pro_XL`.
    public static func readableName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
    }

    /// The program's file name in lowercase, without `.exe`, from a Mac or Windows path. Windows
    /// doesn't tell names apart by case.
    private static func programName(_ path: String) -> String {
        let name = (path.split { $0 == "/" || $0 == "\\" }.last.map(String.init) ?? path).lowercased()
        return name.hasSuffix(".exe") ? String(name.dropLast(4)) : name
    }

    /// The path in lowercase, with Windows' backslashes as slashes.
    private static func folders(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").lowercased()
    }
}
