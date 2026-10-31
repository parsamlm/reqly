import LinuxDesktop
import Testing

@testable import ReqlyApp

@Suite struct TerminalWordsTests {
    @Test func saysWhenReqlyIsntCapturingYet() {
        #expect(TerminalWords.opened(isCapturing: true) == "Opened a terminal set up for Reqly")
        #expect(
            TerminalWords.opened(isCapturing: false) == "Opened a terminal set up for Reqly. Reqly isn't capturing yet."
        )
    }

    @Test func namesTheShellCopiedFor() {
        #expect(TerminalWords.copied(for: .posix) == "Copied the terminal setup for bash and zsh")
        #expect(TerminalWords.copied(for: .fish) == "Copied the terminal setup for fish")
    }

    @Test func listsEveryTerminalReqlyLooksFor() {
        #expect(
            TerminalWords.noTerminal
                == "Reqly looks for xdg-terminal-exec, Ptyxis, GNOME Console, GNOME Terminal, Konsole, Xfce Terminal, "
                + "xterm and x-terminal-emulator, and found none. Install one of them, or paste what Copy Terminal "
                + "Setup copies into the terminal you use.")
    }
}
