import Foundation
import Testing

@testable import LinuxDesktop

@Suite struct TerminalTests {
    static let certificates = TerminalSetup.Certificates(
        bundle: URL(filePath: "/home/ana/.local/share/reqly/ca-certificates.crt"),
        root: URL(filePath: "/home/ana/.local/share/reqly/Reqly CA.pem"))

    @Test func writesTheTextForBashAndZsh() {
        #expect(
            TerminalSetup(port: 9090, certificates: nil).text(for: .posix) == """
                export http_proxy=http://127.0.0.1:9090 https_proxy=http://127.0.0.1:9090
                export HTTP_PROXY=http://127.0.0.1:9090 HTTPS_PROXY=http://127.0.0.1:9090
                export no_proxy=localhost,127.0.0.1,::1 NO_PROXY=localhost,127.0.0.1,::1
                export NODE_USE_ENV_PROXY=1

                """)
        let text = TerminalSetup(port: 9090, certificates: Self.certificates).text(for: .posix)
        #expect(
            text.hasSuffix(
                """
                export NODE_USE_ENV_PROXY=1 SSL_CERT_FILE=/home/ana/.local/share/reqly/ca-certificates.crt
                export REQUESTS_CA_BUNDLE=/home/ana/.local/share/reqly/ca-certificates.crt \
                CURL_CA_BUNDLE=/home/ana/.local/share/reqly/ca-certificates.crt
                export GIT_SSL_CAINFO=/home/ana/.local/share/reqly/ca-certificates.crt \
                NODE_EXTRA_CA_CERTS='/home/ana/.local/share/reqly/Reqly CA.pem'

                """))
    }

    @Test func writesTheTextForFish() {
        #expect(
            TerminalSetup(port: 9091, certificates: Self.certificates).text(for: .fish) == """
                set -gx http_proxy http://127.0.0.1:9091
                set -gx https_proxy http://127.0.0.1:9091
                set -gx HTTP_PROXY http://127.0.0.1:9091
                set -gx HTTPS_PROXY http://127.0.0.1:9091
                set -gx no_proxy localhost,127.0.0.1,::1
                set -gx NO_PROXY localhost,127.0.0.1,::1
                set -gx NODE_USE_ENV_PROXY 1
                set -gx SSL_CERT_FILE /home/ana/.local/share/reqly/ca-certificates.crt
                set -gx REQUESTS_CA_BUNDLE /home/ana/.local/share/reqly/ca-certificates.crt
                set -gx CURL_CA_BUNDLE /home/ana/.local/share/reqly/ca-certificates.crt
                set -gx GIT_SSL_CAINFO /home/ana/.local/share/reqly/ca-certificates.crt
                set -gx NODE_EXTRA_CA_CERTS '/home/ana/.local/share/reqly/Reqly CA.pem'

                """)
    }

    @Test func picksTheShellFromSHELL() {
        #expect(TerminalSetup.Shell(shell: "/usr/bin/fish") == .fish)
        #expect(TerminalSetup.Shell(shell: "/bin/zsh") == .posix)
        #expect(TerminalSetup.Shell(shell: nil) == .posix)
    }

    @Test func quotesForEachShell() {
        #expect(TerminalSetup.posixQuoted("/plain/path-1.pem") == "/plain/path-1.pem")
        #expect(TerminalSetup.posixQuoted("ana's $HOME") == #"'ana'\''s $HOME'"#)
        #expect(TerminalSetup.fishQuoted(#"ana's \ $HOME"#) == #"'ana\'s \\ $HOME'"#)
        #expect(TerminalSetup.posixQuoted("") == "''")
    }

    @Test func removesTheProxyVariables() {
        let environment = ["HTTPS_PROXY": "x", "http_proxy": "y", "no_proxy": "z", "PATH": "/usr/bin"]
        #expect(TerminalSetup.withoutProxyVariables(environment) == ["PATH": "/usr/bin"])
    }

    /// A folder standing in for `PATH`, with a program for each name.
    static func path(with programs: [String], in folder: URL) throws -> String {
        for name in programs {
            let file = folder.appending(path: name)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            chmod(file.path, 0o755)
        }
        return folder.path
    }

    @Test func choosesTheTerminal() throws {
        let gnome = SessionDesktop(currentDesktop: "ubuntu:GNOME")
        let kde = SessionDesktop(currentDesktop: "KDE")
        func chosen(_ programs: [String], _ desktop: SessionDesktop) throws -> Terminal.Kind? {
            let folder = try TestEnvironment.folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            return Terminal.choose(path: try Self.path(with: programs, in: folder), desktop: desktop)?.kind
        }
        // Ubuntu 26.04: the default terminal through the spec.
        #expect(try chosen(["xdg-terminal-exec", "ptyxis", "konsole"], kde) == .xdgTerminalExec)
        // Plasma: Konsole, ahead of Debian's choice.
        #expect(try chosen(["x-terminal-emulator", "konsole"], kde) == .konsole)
        // Ubuntu 24.04 and Debian's GNOME: Debian's choice.
        #expect(try chosen(["x-terminal-emulator", "gnome-terminal", "konsole"], gnome) == .xTerminalEmulator)
        #expect(try chosen(["xterm", "kgx", "gnome-terminal"], gnome) == .kgx)
        #expect(try chosen(["xterm", "konsole"], gnome) == .konsole)
        #expect(try chosen(["xterm"], gnome) == .xterm)
        #expect(try chosen([], gnome) == nil)

        // A file that can't run doesn't count.
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appending(path: "ptyxis"))
        let path = try Self.path(with: ["xterm"], in: folder)
        let terminal = Terminal.choose(path: path, desktop: gnome)
        #expect(terminal == Terminal(kind: .xterm, program: folder.path + "/xterm"))
    }

    @Test func givesEachTerminalItsCommand() {
        let command = ["/usr/bin/env", "A=1", "/bin/bash"]
        let expected: [Terminal.Kind: [String]] = [
            .xdgTerminalExec: command,
            .ptyxis: ["--new-window", "--"] + command,
            .kgx: ["--"] + command,
            .gnomeTerminal: ["--"] + command,
            .konsole: ["-e"] + command,
            .xfce4Terminal: ["-x"] + command,
            .xterm: ["-e"] + command,
            .xTerminalEmulator: ["-e"] + command,
        ]
        for kind in Terminal.Kind.allCases {
            #expect(
                Terminal(kind: kind, program: "/usr/bin/\(kind.rawValue)").arguments(running: command) == expected[kind]
            )
        }
    }

    @Test func runsYourShellThroughEnv() {
        let setup = TerminalSetup(port: 9090, certificates: nil)
        let command = Terminal.command(setup: setup, shell: "/usr/bin/fish")
        #expect(command.first == "/usr/bin/env")
        #expect(command.last == "/usr/bin/fish")
        // GNOME Terminal's all_proxy, from a SOCKS proxy in GNOME's setting, doesn't reach the shell.
        #expect(Array(command[1..<5]) == ["-u", "all_proxy", "-u", "ALL_PROXY"])
        #expect(command.contains("http_proxy=http://127.0.0.1:9090"))
        #expect(command.contains("NODE_USE_ENV_PROXY=1"))
        #expect(Terminal.command(setup: setup, shell: nil).last == "/bin/bash")
        #expect(Terminal.command(setup: setup, shell: "fish").last == "/bin/bash")
    }

    /// The terminal starts detached, with the session's variables and the setup's.
    @Test func opensTheTerminalWithTheVariables() throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appending(path: "environment")
        // A stand-in for xterm that runs its command, which prints the environment it gets.
        let xterm = folder.appending(path: "xterm")
        try Data("#!/bin/sh\nshift\n\"$@\" > '\(output.path)'\n".utf8).write(to: xterm)
        chmod(xterm.path, 0o755)
        let shell = folder.appending(path: "shell")
        try Data("#!/bin/sh\nenv\n".utf8).write(to: shell)
        chmod(shell.path, 0o755)
        try Terminal.open(
            setup: TerminalSetup(port: 9090, certificates: nil),
            environment: [
                "PATH": folder.path + ":/usr/bin:/bin", "SHELL": shell.path, "XDG_CURRENT_DESKTOP": "ubuntu:GNOME",
                "ALL_PROXY": "socks://socks.example.test:1080/",
            ])
        var waited = 0
        while (try? String(contentsOf: output, encoding: .utf8))?.contains("PATH=") != true && waited < 50 {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 1
        }
        let environment = try String(contentsOf: output, encoding: .utf8).split(separator: "\n")
        #expect(environment.contains("XDG_CURRENT_DESKTOP=ubuntu:GNOME"))
        #expect(environment.contains("https_proxy=http://127.0.0.1:9090"))
        #expect(environment.contains("NO_PROXY=localhost,127.0.0.1,::1"))
        #expect(!environment.contains { $0.hasPrefix("ALL_PROXY=") })
    }

    /// With systemd's user manager, the terminal starts in a scope of its own, through
    /// `systemd-run`, named as launchers name an app's, so its shells never stay in Reqly's unit.
    @Test func opensTheTerminalInAScopeOfItsOwn() throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runtime = folder.appending(path: "runtime")
        try FileManager.default.createDirectory(
            at: runtime.appending(path: "systemd"), withIntermediateDirectories: true)
        try Data().write(to: runtime.appending(path: "systemd/private"))
        let scoped = folder.appending(path: "scoped")
        // A stand-in for systemd-run that notes its arguments, then runs what follows `--`.
        let systemdRun = folder.appending(path: "systemd-run")
        try Data(
            """
            #!/bin/sh
            printf '%s\\n' "$@" > '\(scoped.path)'
            while [ "$1" != "--" ]; do shift; done
            shift
            exec "$@"

            """.utf8
        ).write(to: systemdRun)
        chmod(systemdRun.path, 0o755)
        let ran = folder.appending(path: "ran")
        let konsole = folder.appending(path: "konsole")
        try Data("#!/bin/sh\necho \"$@\" > '\(ran.path)'\n".utf8).write(to: konsole)
        chmod(konsole.path, 0o755)
        let environment = [
            "PATH": folder.path + ":/usr/bin:/bin", "SHELL": "/bin/sh", "XDG_CURRENT_DESKTOP": "KDE",
            "XDG_RUNTIME_DIR": runtime.path,
        ]
        try Terminal.open(setup: TerminalSetup(port: 9090, certificates: nil), environment: environment)
        var waited = 0
        while !FileManager.default.fileExists(atPath: ran.path) && waited < 50 {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 1
        }
        let arguments = try String(contentsOf: scoped, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(Array(arguments.prefix(5)) == ["--user", "--scope", "--quiet", "--collect", arguments[4]])
        #expect(arguments[4].hasPrefix("--unit=app-org.kde.konsole-") && arguments[4].hasSuffix(".scope"))
        #expect(arguments.contains(konsole.path))
        #expect(try String(contentsOf: ran, encoding: .utf8).hasPrefix("-e /usr/bin/env -u all_proxy"))

        // Without the user manager, it starts as Reqly's child.
        try FileManager.default.removeItem(at: runtime.appending(path: "systemd/private"))
        #expect(
            Terminal.scopedCommand(Terminal(kind: .konsole, program: konsole.path), [], environment: environment) == nil
        )
    }

    @Test func namesTheScopeAfterTheTerminal() {
        let random = UUID(uuidString: "0B3A4C5D-6E7F-4A8B-9C0D-1E2F3A4B5C6D")!
        let names = Terminal.Kind.allCases.map {
            Terminal.scopeName(Terminal(kind: $0, program: "/nowhere/\($0.rawValue)"), random: random)
        }
        #expect(
            names == [
                "app-xdg\\x2dterminal\\x2dexec-0b3a4c5d-6e7f-4a8b-9c0d-1e2f3a4b5c6d.scope",
                "app-org.gnome.Ptyxis-0b3a4c5d-6e7f-4a8b-9c0d-1e2f3a4b5c6d.scope",
                "app-org.gnome.Console-0b3a4c5d-6e7f-4a8b-9c0d-1e2f3a4b5c6d.scope",
                "app-org.gnome.Terminal-0b3a4c5d-6e7f-4a8b-9c0d-1e2f3a4b5c6d.scope",
                "app-org.kde.konsole-0b3a4c5d-6e7f-4a8b-9c0d-1e2f3a4b5c6d.scope",
                "app-xfce4\\x2dterminal-0b3a4c5d-6e7f-4a8b-9c0d-1e2f3a4b5c6d.scope",
                "app-xterm-0b3a4c5d-6e7f-4a8b-9c0d-1e2f3a4b5c6d.scope",
                "app-x\\x2dterminal\\x2demulator-0b3a4c5d-6e7f-4a8b-9c0d-1e2f3a4b5c6d.scope",
            ])
    }

    /// Debian's x-terminal-emulator leads to the terminal it stands for, through its links.
    @Test func findsTheTerminalBehindXTerminalEmulator() throws {
        let folder = try TestEnvironment.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let wrapper = folder.appending(path: "gnome-terminal.wrapper")
        try Data("#!/bin/sh\n".utf8).write(to: wrapper)
        let alternative = folder.appending(path: "x-terminal-emulator")
        try FileManager.default.createSymbolicLink(at: alternative, withDestinationURL: wrapper)
        #expect(
            Terminal.desktopID(Terminal(kind: .xTerminalEmulator, program: alternative.path)) == "org.gnome.Terminal")
    }
}
