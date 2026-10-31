import AppSetup
import CoreInterface
import Foundation
import LinuxDesktop
import LinuxSystem
import LinuxTrust

/// `reqly --remove-certificate`: removes Reqly's certificate for your account, with no window, for
/// scripts or before uninstalling Reqly: from your browsers, Firefox and the computer's list,
/// which asks for an administrator's password, and its key from your keyring or its file. It says
/// how each place went, and returns 0 once nothing of the certificate is left for your account.
/// Where Reqly can't ask for the password, it gives the commands that take the certificate out of
/// the computer's list by hand. With `--root-stand-in`, only the stand-in file goes.
func removeCertificateFromCommandLine(options: Options) -> Int32 {
    if let standIn = options.rootStandIn {
        switch RootRemoval.remove(rootFile: standIn, standIn: true, system: options.systemParts) {
        case .removed:
            print("Removed this test run's certificate.")
            return 0
        case .nothing:
            print("There's no certificate to remove.")
            return 0
        case .declined, .failed:
            StandardError.write("Reqly couldn't remove this test run's certificate.\n")
            return 1
        }
    }
    // The Reqly that's open would go on decrypting with the certificate, and could trust it again
    // once its key had gone.
    if ProxyGuard.isRunning() {
        StandardError.write("Reqly is open. Quit Reqly first, then remove its certificate.\n")
        return 1
    }
    var store = SystemParts.linuxRootStore(
        file: AppFolders(options: options).rootFile, trustHelper: options.trustHelper)
    // On a desktop with no polkit agent, pkexec asks in this terminal instead. Over SSH, polkit
    // doesn't allow it at all, and the report gives the commands to run with sudo.
    store.helper.asksInTerminal = true
    let report = RemovalReport.remove(from: store)
    // Each place and the key, then how it went, which goes to standard error when something's left.
    let lines = report.lines
    for line in lines.dropLast() {
        print(line)
    }
    if report.isComplete {
        print(lines.last ?? "")
        return 0
    }
    StandardError.write((lines.last ?? "") + "\n")
    return 1
}
