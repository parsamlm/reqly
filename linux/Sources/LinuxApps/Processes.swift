import Glibc

/// A process on this computer, as `/proc` describes it.
public struct RunningProcess: Hashable, Sendable {
    public var pid: Int32
    /// Its program, from `/proc/<pid>/exe`, with links followed. `nil` when the process hides it,
    /// as one that isn't dumpable, such as ssh-agent, or another user's does.
    public var path: String?
    /// Its name as `ps` shows it, such as `curl` or `python3`.
    public var name: String
    /// The arguments it was started with, its program's name first.
    public var arguments: [String]

    public init(pid: Int32, path: String?, name: String, arguments: [String]) {
        self.pid = pid
        self.path = path
        self.name = name
        self.arguments = arguments
    }

    /// The programs it may be run from, for matching it to a desktop entry: its own, and for an
    /// interpreter, such as `python3 /usr/bin/gnome-tweaks`, the script it runs.
    public var programs: [String] {
        var programs: [String] = []
        let own = path ?? arguments.first.flatMap { $0.hasPrefix("/") ? $0 : nil }
        if let own {
            programs.append(own)
        }
        if Processes.isInterpreter(LinuxFile.fileName(own ?? arguments.first ?? name)),
            let script = arguments.dropFirst().first(where: { !$0.hasPrefix("-") })
        {
            programs.append(script)
        }
        return programs
    }
}

/// Reads the processes on this computer from `/proc`, or from a folder laid out the same way in
/// tests.
public enum Processes {
    /// Every process's ID.
    public static func all(in proc: String = "/proc") -> [Int32] {
        LinuxFile.names(in: proc).compactMap { Int32($0) }
    }

    /// A process, or `nil` when it has ended.
    public static func read(_ pid: Int32, in proc: String = "/proc") -> RunningProcess? {
        let folder = "\(proc)/\(pid)"
        // Anyone may read a process's comm and cmdline, even one that hides its open files.
        guard let comm = LinuxFile.text(folder + "/comm", limit: 64) else { return nil }
        let arguments = Self.arguments(of: pid, in: proc) ?? []
        let path = program(of: pid, in: proc)
        return RunningProcess(
            pid: pid, path: path,
            name: name(comm: comm.trimmingNewline, path: path, arguments: arguments), arguments: arguments)
    }

    /// A process's program, or `nil` when it hides it.
    public static func program(of pid: Int32, in proc: String = "/proc") -> String? {
        guard var path = LinuxFile.link("\(proc)/\(pid)/exe") else { return nil }
        // The program's file was replaced since it started, as an upgrade does.
        if path.hasSuffix(" (deleted)") {
            path.removeLast(" (deleted)".count)
        }
        return path
    }

    /// The arguments a process was started with.
    public static func arguments(of pid: Int32, in proc: String = "/proc") -> [String]? {
        guard let bytes = LinuxFile.bytes("\(proc)/\(pid)/cmdline", limit: 64 * 1024) else { return nil }
        return bytes.split(separator: 0, omittingEmptySubsequences: false).dropLast(bytes.last == 0 ? 1 : 0)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// When a process started, in clock ticks since the computer started, which tells it apart
    /// from a later process given the same ID.
    public static func startTime(of pid: Int32, in proc: String = "/proc") -> UInt64? {
        guard let line = LinuxFile.text("\(proc)/\(pid)/stat", limit: 4096),
            let close = line.lastIndex(of: ")")
        else { return nil }
        // The fields after the name, which is in brackets and may hold spaces: state is the 3rd
        // field of the line, and the start time the 22nd.
        let fields = line[line.index(after: close)...].split(separator: " ")
        return fields.count > 19 ? UInt64(fields[19]) : nil
    }

    /// The process that has the socket with this inode open, looking only in `pids`, in order.
    /// - Returns: The process, if one of them has it, and the ones whose open files this user may
    ///   not read.
    public static func holder(
        ofSocket inode: UInt64, among pids: [Int32], in proc: String = "/proc"
    ) -> (pid: Int32?, hidden: [Int32]) {
        let target = "socket:[\(inode)]"
        var hidden: [Int32] = []
        for pid in pids {
            let folder = "\(proc)/\(pid)/fd"
            switch LinuxFile.entries(in: folder).listing {
            case .names(let descriptors):
                for descriptor in descriptors where LinuxFile.link(folder + "/" + descriptor) == target {
                    return (pid, hidden)
                }
            case .denied:
                hidden.append(pid)
            case .missing:
                break
            }
        }
        return (nil, hidden)
    }

    /// The Flatpak a process runs in, from the `.flatpak-info` file at its root, such as
    /// `org.mozilla.firefox`.
    public static func flatpakID(of pid: Int32, in proc: String = "/proc") -> String? {
        guard let info = LinuxFile.text("\(proc)/\(pid)/root/.flatpak-info", limit: 64 * 1024) else { return nil }
        var group = ""
        for line in info.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("[") {
                group = String(line)
            } else if group == "[Application]", line.hasPrefix("name=") {
                return String(line.dropFirst("name=".count))
            }
        }
        return nil
    }

    /// The name to show for a process: its program's file name, or, when it was run through a
    /// link with another name, such as `python3` for `python3.12`, that name. comm holds at most
    /// 15 characters, and a process may change it, as Firefox's do.
    static func name(comm: String, path: String?, arguments: [String]) -> String {
        let program = path.map(LinuxFile.fileName)
        if let program, program == comm || (comm.count == 15 && program.hasPrefix(comm)) {
            return program
        }
        if let first = arguments.first.map(LinuxFile.fileName), !first.isEmpty, first.hasPrefix(comm) {
            return first
        }
        return program ?? comm
    }

    /// Programs that run a script named in their arguments, so the script names what runs.
    static func isInterpreter(_ name: String) -> Bool {
        let plain: Set<String> = [
            "sh", "bash", "dash", "zsh", "env", "perl", "ruby", "node", "nodejs", "gjs", "java", "mono", "python",
        ]
        return plain.contains(name) || name.hasPrefix("python") || name.hasPrefix("perl5") || name.hasPrefix("ruby")
    }
}

extension String {
    /// The text without the newline that ends a line read from `/proc`.
    var trimmingNewline: String {
        hasSuffix("\n") ? String(dropLast()) : self
    }
}
