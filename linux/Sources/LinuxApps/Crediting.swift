import DeviceBridge
import ReqlyModel

/// Decides where a connection's traffic is credited, from the unit it was made in and the process
/// that has it, as the Mac does: to the app, when the process is the app's program, one of its
/// helpers, or inside its install folder, snap or Flatpak; to a command-line tool by its own name,
/// such as git started by VS Code or curl in a terminal; and to an Android emulator, as a device.
public enum Crediting {
    /// The Android emulator a process works for, by the rules the Mac and Windows share: a
    /// `qemu-system-*` from the SDK's `emulator/qemu/linux-<arch>/` folder is the emulator in its
    /// `-avd` argument, and netsimd carries every emulator's Wi-Fi.
    /// - Parameter emulators: The arguments of each emulator that's running. They're read only
    ///   for netsimd.
    public static func device(of process: RunningProcess, emulators: () -> [[String]]) -> Device? {
        guard let path = process.path ?? process.arguments.first else { return nil }
        // Linux runs qemu-system-* for virtual machines too, as GNOME Boxes and virt-manager do.
        // Only the Android SDK's is an emulator.
        if EmulatorProcesses.isEmulator(path), !path.contains("/emulator/"),
            EmulatorProcesses.virtualDevice(in: process.arguments) == nil
        {
            return nil
        }
        return EmulatorProcesses.device(ofProgram: path, arguments: { process.arguments }, emulators: emulators)
    }

    /// The app or tool a connection is credited to.
    /// - Parameters:
    ///   - unit: The unit the connection's socket was made in.
    ///   - process: The process that has the socket, if it was found. Its program is `nil` when it
    ///     hides it.
    ///   - leader: The program of the process the unit was made for, its first.
    ///   - entries: The desktop entries, which name apps.
    ///   - flatpakID: The Flatpak the process runs in, when that's known from the process.
    public static func source(
        unit: SystemdUnit, process: RunningProcess?, leader: String?, entries: DesktopEntries,
        flatpakID: String? = nil
    ) -> Source? {
        switch unit.kind {
        case .app, .flatpak, .snap:
            guard let id = unit.desktopID else { return nil }
            let entry = entry(of: unit, id: id, entries: entries)
            // A terminal's own units hold the commands you run in it.
            if entry?.isTerminalEmulator ?? SystemdUnit.terminals.contains(id) {
                return process.map { source(of: $0, entries: entries, flatpakID: flatpakID) }
            }
            if let process, countsAsItself(process, in: unit, entry: entry, leader: leader) {
                return source(of: process, entries: entries, flatpakID: flatpakID)
            }
            return app(entry, id: id, unit: unit, process: process, leader: leader)
        case .terminal, .other:
            return process.map { source(of: $0, entries: entries, flatpakID: flatpakID) }
        case .service(let name):
            // Another user's process, such as a system service's, hides its program, but its
            // unit still names it.
            guard let process else { return Source(name: name) }
            return source(of: process, entries: entries, flatpakID: flatpakID)
        }
    }

    /// The process's app, from the desktop entry it matches, or the tool it is.
    public static func source(of process: RunningProcess, entries: DesktopEntries, flatpakID: String? = nil) -> Source {
        if let entry = entries.entry(for: process, flatpakID: flatpakID) {
            return Source(name: entry.name, bundleID: entry.id, path: path(of: entry) ?? process.path)
        }
        // A process that hides its program still shows the path it was started from.
        return Source(name: process.name, path: process.path ?? process.programs.first)
    }

    /// The desktop entry of the app a unit is for.
    private static func entry(of unit: SystemdUnit, id: String, entries: DesktopEntries) -> DesktopEntry? {
        if let entry = entries.entry(id: id) {
            return entry
        }
        if case .snap(let name, _) = unit.kind {
            return entries.entries(ofSnap: name).first
        }
        return nil
    }

    /// The app a unit is for, named by its entry, or by its ID when it has none.
    private static func app(
        _ entry: DesktopEntry?, id: String, unit: SystemdUnit, process: RunningProcess?, leader: String?
    ) -> Source {
        if let entry {
            // A Flatpak's entry names no program, so its first process's stands in for all of them.
            return Source(name: entry.name, bundleID: entry.id, path: path(of: entry) ?? leader ?? process?.path)
        }
        let name: String
        switch unit.kind {
        case .snap(let snap, let app):
            name = app == snap ? snap : "\(snap) \(app)"
        default:
            // Such as Calculator for org.gnome.Calculator.
            let parts = id.split(separator: ".")
            name = parts.count >= 3 ? String(parts.last!) : id
        }
        return Source(name: name, bundleID: id, path: process?.path)
    }

    /// The program an app's traffic is credited to, the same for all its processes: its entry's,
    /// such as `/usr/bin/gnome-calculator` or `/snap/bin/firefox`. `nil` for a Flatpak, whose
    /// entry starts `flatpak`.
    private static func path(of entry: DesktopEntry) -> String? {
        entry.program.flatMap { $0.hasPrefix("/") ? $0 : nil }
    }

    /// Whether a process in an app's unit is a command-line tool the app started, such as git
    /// started by VS Code, rather than the app or one of its helpers. A tool is a program in a
    /// `bin` folder outside the app's own folders that isn't the app's program.
    static func countsAsItself(
        _ process: RunningProcess, in unit: SystemdUnit, entry: DesktopEntry?, leader: String?
    ) -> Bool {
        guard let path = process.path else { return false }
        if path == leader {
            return false
        }
        if let program = entry?.program, process.programs.contains(where: { $0 == program }) {
            return false
        }
        if let program = entry?.program, program.hasPrefix("/"), let resolved = LinuxFile.resolved(program),
            process.programs.contains(resolved)
                || DesktopEntries.installFolder(of: resolved).map({ path.hasPrefix($0 + "/") }) == true
        {
            return false
        }
        switch unit.kind {
        case .snap(let name, _) where path.hasPrefix("/snap/\(name)/"):
            return false
        case .flatpak where path.hasPrefix("/app/"):
            return false
        default:
            break
        }
        return ["bin", "sbin", "games"].contains(LinuxFile.fileName(LinuxFile.folder(path)))
    }
}
