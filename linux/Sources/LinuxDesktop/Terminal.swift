import Foundation

/// A terminal app Reqly can open, set up for it, and how each takes the command to run.
public struct Terminal: Hashable, Sendable {
    /// The terminals Reqly knows, by their programs' names.
    public enum Kind: String, CaseIterable, Sendable {
        /// The default terminal, through the XDG terminal spec: Ptyxis on Ubuntu 26.04.
        case xdgTerminalExec = "xdg-terminal-exec"
        case ptyxis
        /// GNOME Console.
        case kgx
        case gnomeTerminal = "gnome-terminal"
        case konsole
        case xfce4Terminal = "xfce4-terminal"
        case xterm
        /// Debian's and Ubuntu's choice of terminal: GNOME Terminal on Ubuntu 24.04 and Debian.
        case xTerminalEmulator = "x-terminal-emulator"
    }

    public var kind: Kind
    /// Its program, such as `/usr/bin/ptyxis`.
    public var program: String

    public init(kind: Kind, program: String) {
        self.kind = kind
        self.program = program
    }

    /// The arguments, after the program's name, that open a window running `command`.
    public func arguments(running command: [String]) -> [String] {
        switch kind {
        case .xdgTerminalExec: command
        case .ptyxis: ["--new-window", "--"] + command
        case .kgx, .gnomeTerminal: ["--"] + command
        case .konsole, .xterm, .xTerminalEmulator: ["-e"] + command
        case .xfce4Terminal: ["-x"] + command
        }
    }

    /// The terminal to open: the default one through `xdg-terminal-exec`, wherever it's
    /// installed; on KDE, Konsole; otherwise `x-terminal-emulator`; otherwise the first one found
    /// of Ptyxis, GNOME Console, GNOME Terminal, Konsole, Xfce's and xterm. `nil` when there's none
    /// in `path`, such as the `PATH` variable's.
    public static func choose(path: String?, desktop: SessionDesktop) -> Terminal? {
        var order: [Kind] = [.xdgTerminalExec]
        if desktop.isKDE {
            order.append(.konsole)
        }
        order += [.xTerminalEmulator, .ptyxis, .kgx, .gnomeTerminal, .konsole, .xfce4Terminal, .xterm]
        for kind in order {
            if let program = Programs.find(kind.rawValue, in: path) {
                return Terminal(kind: kind, program: program)
            }
        }
        return nil
    }

    /// The command a terminal runs: your shell, through `env`, which sets the variables first,
    /// so they reach the shell whatever the terminal passes on, and unsets `all_proxy`, which
    /// GNOME Terminal sets from a SOCKS proxy in GNOME's setting.
    public static func command(setup: TerminalSetup, shell: String?) -> [String] {
        let shell = shell.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/bash"
        return ["/usr/bin/env", "-u", "all_proxy", "-u", "ALL_PROXY"]
            + setup.variables.map { "\($0.name)=\($0.value)" } + [shell]
    }

    /// Opens a window running your shell, set up for Reqly, detached, with `environment`, the
    /// session's own, so apps there keep `XDG_CURRENT_DESKTOP`, which GIO's proxy lookup needs.
    /// Throws when there's no terminal, or it couldn't start. It may wait half a second, so call
    /// it off the main thread.
    ///
    /// The terminal starts in a systemd scope of its own, as your desktop's launcher starts apps,
    /// since Konsole leaves its first shell where it started: in Reqly's own unit, that shell's
    /// commands would be credited to Reqly, would keep the unit going after Reqly quits, and would
    /// end with it. Without systemd's user manager, it starts as Reqly's child.
    public static func open(setup: TerminalSetup, environment: [String: String]) throws {
        let desktop = SessionDesktop(currentDesktop: environment["XDG_CURRENT_DESKTOP"])
        guard let terminal = choose(path: environment["PATH"], desktop: desktop) else {
            throw Programs.Failure(program: "a terminal", code: ENOENT)
        }
        let arguments = terminal.arguments(running: command(setup: setup, shell: environment["SHELL"]))
        if let scoped = scopedCommand(terminal, arguments, environment: environment),
            let started = try? Programs.start(scoped[0], Array(scoped.dropFirst()), environment: environment)
        {
            // systemd-run ends at once only when it couldn't make the scope. The terminal may end
            // soon too, having asked its server for the window, as GNOME Terminal's does.
            guard let status = Programs.ended(started, within: 0.5), status != 0 else { return }
        }
        let pid = try Programs.start(terminal.program, arguments, environment: environment)
        Programs.reapWhenDone(pid)
    }

    /// `systemd-run`'s command that runs the terminal in a scope of its own, named as launchers
    /// name an app's, `app-<desktop ID>-<random>.scope`, or `nil` without `systemd-run` or the
    /// user manager it asks.
    static func scopedCommand(_ terminal: Terminal, _ arguments: [String], environment: [String: String]) -> [String]? {
        guard let systemdRun = Programs.find("systemd-run", in: environment["PATH"]),
            let runtime = environment["XDG_RUNTIME_DIR"], runtime.hasPrefix("/"),
            FileManager.default.fileExists(atPath: runtime + "/systemd/private")
        else { return nil }
        return [
            systemdRun, "--user", "--scope", "--quiet", "--collect", "--unit=\(scopeName(terminal, random: UUID()))",
            "--description=Terminal opened by Reqly", "--",
        ] + [terminal.program] + arguments
    }

    /// The scope's name: the terminal's desktop ID, with dashes escaped as systemd escapes them,
    /// and a random UUID, such as `app-org.kde.konsole-<UUID>.scope`.
    static func scopeName(_ terminal: Terminal, random: UUID) -> String {
        let escaped = desktopID(terminal).replacingOccurrences(of: "-", with: "\\x2d")
        return "app-\(escaped)-\(random.uuidString.lowercased()).scope"
    }

    /// The terminal's desktop ID, which LinuxApps knows as a terminal's: its own, or for the two
    /// that open your default terminal, the one `x-terminal-emulator` leads to, or their names.
    static func desktopID(_ terminal: Terminal) -> String {
        var kind = terminal.kind
        if kind == .xTerminalEmulator, let target = realpath(terminal.program, nil) {
            defer { free(target) }
            // Such as /usr/bin/gnome-terminal.wrapper, through /etc/alternatives.
            var name = URL(filePath: String(cString: target)).lastPathComponent
            if name.hasSuffix(".wrapper") {
                name.removeLast(".wrapper".count)
            }
            kind = Kind(rawValue: name) ?? kind
        }
        switch kind {
        case .ptyxis: return "org.gnome.Ptyxis"
        case .kgx: return "org.gnome.Console"
        case .gnomeTerminal: return "org.gnome.Terminal"
        case .konsole: return "org.kde.konsole"
        case .xdgTerminalExec, .xTerminalEmulator, .xfce4Terminal, .xterm: return kind.rawValue
        }
    }
}
