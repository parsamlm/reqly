import CertificateAuthority
import Foundation
import WindowsSystem

/// How removing Reqly's certificate went, as Reqly is uninstalled. The numbers are what
/// `reqly_remove_root` returns.
public enum RootRemoval: Int32, Sendable {
    case removed = 1
    /// There was none, as when HTTPS was never set up or the certificate was removed already.
    case nothing = 0
    /// You said no when Windows asked.
    case declined = 2
    case failed = -1

    /// Removes Reqly's certificate as Reqly is uninstalled: from your trusted roots, which Windows
    /// asks you to confirm, and its key with it. A test run's stand-in file only goes.
    public static func remove(rootFile: String, standIn: Bool) -> RootRemoval {
        let file = URL(fileURLWithPath: rootFile)
        if standIn {
            return remove(from: FileRootStore(file: file))
        }
        #if os(Windows)
            return remove(from: WindowsRootStore(file: file))
        #else
            return .nothing
        #endif
    }

    /// Removes the certificate a store keeps, with its key and the system's trust in it.
    public static func remove(from store: any RootStore) -> RootRemoval {
        let root: RootIdentity?
        do {
            root = try store.load()
        } catch {
            return .failed
        }
        guard let root else { return .nothing }
        do {
            try store.remove(root)
            return .removed
        } catch CertificateStoreError.cancelled {
            return .declined
        } catch {
            return .failed
        }
    }
}
