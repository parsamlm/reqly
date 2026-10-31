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
    /// so they reach the shell whatever the terminal passes on.
    public static func command(setup: TerminalSetup, shell: String?) -> [String] {
        let shell = shell.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/bash"
        return ["/usr/bin/env"] + setup.variables.map { "\($0.name)=\($0.value)" } + [shell]
    }

    /// Opens a window running your shell, set up for Reqly, detached, with `environment`, the
    /// session's own, so apps there keep `XDG_CURRENT_DESKTOP`, which GIO's proxy lookup needs.
    /// Throws when there's no terminal, or it couldn't start.
    public static func open(setup: TerminalSetup, environment: [String: String]) throws {
        let desktop = SessionDesktop(currentDesktop: environment["XDG_CURRENT_DESKTOP"])
        guard let terminal = choose(path: environment["PATH"], desktop: desktop) else {
            throw Programs.Failure(program: "a terminal", code: ENOENT)
        }
        let arguments = terminal.arguments(running: command(setup: setup, shell: environment["SHELL"]))
        let pid = try Programs.start(terminal.program, arguments, environment: environment)
        Programs.reapWhenDone(pid)
    }
}
