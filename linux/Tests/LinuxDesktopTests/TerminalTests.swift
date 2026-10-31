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
    }
}
