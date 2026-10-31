import CertificateAuthority
import Foundation
import ReqlyModel

/// What only the system Reqly runs on has, which the app hands a session as it opens it:
/// WindowsSystem's pieces on Windows, and LinuxSystem's on Linux. A part a system doesn't have
/// stays empty, and sessions go without it, as a saved session does. Test runs' stand-ins, chosen
/// by ``OpenOptions``, take the parts' place.
public struct SystemParts: Sendable {
    /// One of this computer's addresses, as the Devices window shows it.
    public struct Address: Hashable, Sendable {
        /// What the system calls the connection, such as "Wi-Fi" or "Ethernet".
        public var interface: String
        /// Such as `192.168.1.125`.
        public var address: String

        public init(interface: String, address: String) {
            self.interface = interface
            self.address = address
        }
    }

    /// The system's store for Reqly's certificate and key, which keeps them in the file that
    /// `OpenOptions.rootFile` names. Without one, only a test run's stand-in decrypts.
    public var rootStore: (@Sendable (_ file: URL) -> any RootStore)?
    /// Your user's proxy switch, which keeps your own settings in `restoreFile` meanwhile. For a
    /// test run, the same switch on settings kept in the `standIn` file instead of the system's.
    /// Nil where the system has no switch.
    public var proxySwitch: @Sendable (_ restoreFile: URL, _ standIn: URL?) -> (any SystemProxySwitch)?
    /// Finds which app on this computer opened each connection. Each live session makes its own.
    public var appFinder: (@Sendable () -> any AppFinder)?
    /// Where the secrets are kept, such as the upstream proxy's password and client certificates'
    /// private keys: in `file`, encrypted for your user when `isProtected`, or plain for a test run.
    public var secrets: @Sendable (_ file: URL, _ isProtected: Bool) -> any SecretStorage
    /// This computer's addresses on the networks devices can reach, the likeliest first.
    public var networkAddresses: @Sendable () -> [Address]
    /// The hardware address of the device at an IP address on the local network, such as
    /// `aa:bb:cc:dd:ee:ff`, or `nil` when the system doesn't know it.
    public var hardwareAddress: @Sendable (_ ip: String) -> String?

    public init(
        rootStore: (@Sendable (_ file: URL) -> any RootStore)? = nil,
        proxySwitch: @escaping @Sendable (_ restoreFile: URL, _ standIn: URL?) -> (any SystemProxySwitch)? = {
            _, _ in nil
        },
        appFinder: (@Sendable () -> any AppFinder)? = nil,
        secrets: @escaping @Sendable (_ file: URL, _ isProtected: Bool) -> any SecretStorage,
        networkAddresses: @escaping @Sendable () -> [Address] = { [] },
        hardwareAddress: @escaping @Sendable (_ ip: String) -> String? = { _ in nil }
    ) {
        self.rootStore = rootStore
        self.proxySwitch = proxySwitch
        self.appFinder = appFinder
        self.secrets = secrets
        self.networkAddresses = networkAddresses
        self.hardwareAddress = hardwareAddress
    }
}

/// Finds which app on this computer opened a connection to Reqly.
public protocol AppFinder: Sendable {
    /// What opened the connection from `clientPort` to `proxyPort`: an app on this computer, or
    /// an Android emulator.
    func origin(clientPort: Int, proxyPort: Int) -> Origin?
}

/// Secrets, such as the upstream proxy's password and client certificates' private keys, kept
/// together, by name, where only your user can read them.
public protocol SecretStorage: Sendable {
    /// Each secret by its name, such as `Reqly Upstream Proxy/password`, or none if there are none yet.
    func load() throws -> [String: Data]
    func save(_ secrets: [String: Data]) throws
}
