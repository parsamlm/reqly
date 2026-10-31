import CGtk
import Foundation
import GtkBinding
import LinuxDesktop

extension MainWindow {
    /// Open Terminal: opens your terminal, with the variables that send command-line tools
    /// through Reqly, and make them trust its certificate once HTTPS is set up.
    func openTerminal() {
        openTerminal(environment: ProcessInfo.processInfo.environment)
    }

    /// Opens the terminal found through `environment`'s `PATH`, started with `environment`, such
    /// as the process's own, so the apps in it keep your desktop's variables. The proxy variables
    /// reach its shell however Reqly captures: before it does, they point at the port it will use.
    func openTerminal(environment: [String: String]) {
        let environment = TerminalSetup.withoutProxyVariables(environment)
        let desktop = SessionDesktop(currentDesktop: environment["XDG_CURRENT_DESKTOP"])
        guard Terminal.choose(path: environment["PATH"], desktop: desktop) != nil else {
            let dialog = adw_alert_dialog_new("No Terminal Found", TerminalWords.noTerminal)!
            adw_alert_dialog_add_response(cast(dialog), "ok", "OK")
            adw_dialog_present(dialog, window)
            return
        }
        do {
            try Terminal.open(setup: terminalSetup, environment: environment)
            toast(TerminalWords.opened(isCapturing: model.isCapturing))
        } catch {
            toast("\(error)")
        }
    }

    /// Copy Terminal Setup: copies the lines that set those variables, for your shell, as `SHELL`
    /// names it.
    func copyTerminalSetup() {
        copyTerminalSetup(shell: ProcessInfo.processInfo.environment["SHELL"])
    }

    /// Copies the lines for `shell`, such as `/usr/bin/fish`.
    func copyTerminalSetup(shell: String?) {
        let shell = TerminalSetup.Shell(shell: shell)
        gdk_clipboard_set_text(gtk_widget_get_clipboard(window), terminalSetup.text(for: shell))
        toast(TerminalWords.copied(for: shell))
    }

    /// The variables for the port Reqly captures on, or will, with the certificate's once HTTPS is
    /// set up.
    private var terminalSetup: TerminalSetup {
        TerminalSetup(port: model.port, certificates: model.terminalCertificates())
    }
}

/// What Open Terminal and Copy Terminal Setup say.
enum TerminalWords {
    static func opened(isCapturing: Bool) -> String {
        isCapturing
            ? "Opened a terminal set up for Reqly" : "Opened a terminal set up for Reqly. Reqly isn't capturing yet."
    }

    static func copied(for shell: TerminalSetup.Shell) -> String {
        switch shell {
        case .posix: "Copied the terminal setup for bash and zsh"
        case .fish: "Copied the terminal setup for fish"
        }
    }

    /// Which terminals Reqly looks for, when it finds none.
    static var noTerminal: String {
        let names = Terminal.Kind.allCases.map(name)
        return "Reqly looks for \(names.dropLast().joined(separator: ", ")) and \(names.last!), and found none. "
            + "Install one of them, or paste what Copy Terminal Setup copies into the terminal you use."
    }

    /// A terminal's name, or for the two that open your default terminal, their programs'.
    static func name(of kind: Terminal.Kind) -> String {
        switch kind {
        case .xdgTerminalExec, .xTerminalEmulator, .xterm: kind.rawValue
        case .ptyxis: "Ptyxis"
        case .kgx: "GNOME Console"
        case .gnomeTerminal: "GNOME Terminal"
        case .konsole: "Konsole"
        case .xfce4Terminal: "Xfce Terminal"
        }
    }
}
