import CertificateAuthority
import CoreInterface
import Foundation
import LinuxApps
import LinuxDesktop
import LinuxTrust
import ReqlyModel

extension SystemParts {
    /// Linux's own parts: your desktop's proxy setting, GNOME's and KDE's, from LinuxDesktop;
    /// Reqly's certificate, its key in your keyring and the places apps trust it, and the other
    /// secrets, from LinuxTrust; which app opened each connection, this computer's network
    /// addresses and its neighbors' hardware addresses, from LinuxApps; and the lowest port Linux
    /// lets an ordinary user listen on. adb is found where the core looks. The app names the files,
    /// in the folders ``LinuxFolders`` gives. Test runs ask for stand-ins, which never touch the
    /// computer's settings, certificates or keyring.
    public static let linux = linux()

    /// Linux's parts, with the root helper that trusts the certificate in the computer's list at
    /// `trustHelper`, such as a development build's copy, instead of the installed one. pkexec runs
    /// it as root, so keep it where only root can change it, as `sudo install` puts it.
    ///
    /// The certificate store keeps the key in your keyring, and in the file the session's
    /// `rootFile` names only when there's no keyring to use; the certificate's other files go
    /// beside that file, so name one in ``LinuxFolders/data``, as ``LinuxFolders/rootFile`` does.
    /// The secrets work the same way: in your keyring, or in their file, which only you can read.
    public static func linux(trustHelper: String? = nil) -> SystemParts {
        SystemParts(
            rootStore: { file in linuxRootStore(file: file, trustHelper: trustHelper) },
            proxySwitch: { restoreFile, standIn in
                if let standIn {
                    return UserProxySwitch(settings: DesktopProxyStandIn(file: standIn), restoreFile: restoreFile)
                }
                // The guard puts your settings back if Reqly ends while it captures.
                return DesktopProxySwitch(guardian: ProxyGuard(restoreFile: restoreFile))
            },
            // With the entries the app's list finds icons in, so they're read once.
            appFinder: { AppLookup(entries: .shared) },
            secrets: { file, isProtected in KeyringSecrets(file: file, isProtected: isProtected) },
            networkAddresses: {
                NetworkAddresses.current().map { SystemParts.Address(interface: $0.interface, address: $0.address) }
            },
            hardwareAddress: { NetworkNeighbors.hardwareAddress(of: $0) },
            lowestPort: { lowestPort() })
    }

    /// The lowest port Linux lets an ordinary user listen on, which reverse proxies keep to:
    /// `net.ipv4.ip_unprivileged_port_start`, from `file`. It's 1024 unless the system lowered
    /// it, as Docker does to 0, which lets any port be used, so it's 1 then. A kernel too old to
    /// have the setting keeps ports below 1024 for administrators.
    public static func lowestPort(file: String = "/proc/sys/net/ipv4/ip_unprivileged_port_start") -> Int {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8),
            let start = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return 1024 }
        return min(max(start, 1), 65535)
    }

    /// The certificate store Linux's parts give a session for `file`, with the root helper at
    /// `trustHelper`, or the installed one. The app makes its own the same way, to show and change
    /// each place that trusts the certificate, so the two see the same files and keyring.
    public static func linuxRootStore(file: URL, trustHelper: String? = nil) -> LinuxRootStore {
        LinuxRootStore(file: file, helper: trustHelper)
    }
}

extension AppLookup: AppFinder {}

extension KeyringSecrets: SecretStorage {}
