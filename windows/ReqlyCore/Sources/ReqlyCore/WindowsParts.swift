import CertificateAuthority
import CoreInterface
import Foundation
import ReqlyModel
import WindowsSystem

extension SystemParts {
    /// Windows' own parts, from WindowsSystem: your user's certificate store and proxy setting,
    /// which app opened each connection, a secrets file encrypted for your user, and this PC's
    /// network addresses. On the Mac and Linux, where the tests run too, only the stand-ins that
    /// test runs ask for work.
    public static let windows = SystemParts(
        rootStore: windowsRootStore,
        proxySwitch: { restoreFile, standIn in
            if let standIn {
                return UserProxySwitch(
                    settings: FileProxySettings<ProxySettings>(file: standIn), restoreFile: restoreFile)
            }
            #if os(Windows)
                return UserProxySwitch(settings: WinINetProxySettings(), restoreFile: restoreFile)
            #else
                return nil
            #endif
        },
        appFinder: windowsAppFinder,
        secrets: { file, isProtected in SecretFile(file: file, isProtected: isProtected) },
        networkAddresses: {
            NetworkAddresses.current().map { SystemParts.Address(interface: $0.interface, address: $0.address) }
        },
        hardwareAddress: { NetworkNeighbors.hardwareAddress(of: $0) })

    #if os(Windows)
        private static let windowsRootStore: (@Sendable (URL) -> any RootStore)? = { WindowsRootStore(file: $0) }
        private static let windowsAppFinder: (@Sendable () -> any AppFinder)? = { AppLookup() }
    #else
        private static let windowsRootStore: (@Sendable (URL) -> any RootStore)? = nil
        private static let windowsAppFinder: (@Sendable () -> any AppFinder)? = nil
    #endif
}

extension SecretFile: SecretStorage {}

#if os(Windows)
    extension AppLookup: AppFinder {}
#endif
