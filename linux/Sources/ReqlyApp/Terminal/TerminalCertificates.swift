import Foundation
import LinuxDesktop
import LinuxTrust

extension AppModel {
    /// Reqly's certificate files for a terminal set up for Reqly, once HTTPS is set up and
    /// trusted: the certificate alone, and the computer's list with it added, which Reqly's
    /// certificate store keeps beside its file. `nil` before then, or while either file is missing,
    /// so the terminal's tools keep the computer's own list.
    func terminalCertificates() -> TerminalSetup.Certificates? {
        guard https.state?.status == .trusted else { return nil }
        let store = LinuxRootStore(file: folders.rootFile)
        let files = [store.bundleFile, store.pemFile]
        guard files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        return TerminalSetup.Certificates(bundle: store.bundleFile, root: store.pemFile)
    }
}
