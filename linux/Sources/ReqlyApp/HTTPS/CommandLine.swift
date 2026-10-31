import AppSetup
import CoreInterface
import Foundation
import LinuxSystem
import LinuxTrust

/// `reqly --remove-certificate`: removes Reqly's certificate for your account, with no window, for
/// scripts or before uninstalling Reqly: from your browsers, Firefox and the computer's list,
/// which asks for an administrator's password, and its key from your keyring or its file. It says
/// how each place went, and returns 0 once nothing of the certificate is left for your account.
/// With `--root-stand-in`, only the stand-in file goes.
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
            FileHandle.standardError.write(Data("Reqly couldn't remove this test run's certificate.\n".utf8))
            return 1
        }
    }
    var store = SystemParts.linuxRootStore(
        file: AppFolders(options: options).rootFile, trustHelper: options.trustHelper)
    // With no password dialog, as over SSH or on a desktop with no polkit agent, pkexec asks in
    // this terminal instead.
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
    FileHandle.standardError.write(Data(((lines.last ?? "") + "\n").utf8))
    return 1
}
