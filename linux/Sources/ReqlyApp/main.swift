// Reqly for Linux, the program `reqly`: its window, or with the arguments below, a run without one.
import AppSetup
import Foundation
import GtkBinding
import LinuxDesktop

let arguments = Array(CommandLine.arguments.dropFirst())

// The watcher's and the login entry's runs, which put your proxy settings back, and nothing else.
if let status = ProxyGuard.run(arguments: arguments) {
    exit(status)
}

let options: Options
do {
    options = try Options(arguments)
} catch {
    StandardError.write("reqly: \(error)\n")
    exit(2)
}
// A line at a time, so nothing is lost when a test run stops Reqly, and what
// --remove-certificate prints comes in order with its standard error in a pipe or over SSH.
lineBufferedOutput()
switch options.command {
case .removeCertificate:
    exit(removeCertificateFromCommandLine(options: options))
case .help:
    print(Options.help, terminator: "")
    exit(0)
case .version:
    print("Reqly \(App.version)")
    exit(0)
case .open:
    break
}

// The self-check changes what it finds, so it runs only on stand-ins and a scratch home.
if let report = options.smokeReport, let refusal = SelfCheck.refusal(options: options, report: URL(filePath: report)) {
    StandardError.write("reqly: \(refusal)\n")
    exit(2)
}
// A Reqly started from a terminal set up for it would otherwise send its own requests through
// itself.
TerminalSetup.removeProxyVariablesFromThisProcess()
if let logFile = options.logFile {
    let fd = open(logFile, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
    if fd >= 0 {
        dup2(fd, STDERR_FILENO)
        close(fd)
    } else {
        StandardError.write("reqly: couldn't open the log file \(logFile)\n")
    }
}
// Kept for as long as the program runs: GLib's callbacks hold it only weakly.
let app = App(options: options)
exit(app.run())
