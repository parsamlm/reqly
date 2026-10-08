import AppKit
import Capture
import CertificateAuthority
import Foundation
import Keychain
import Observation
import ReqlyModel

/// Reqly's certificate for HTTPS decryption, and the hosts to decrypt.
///
/// The certificate lives in the user's login keychain. Reqly decrypts only while macOS trusts
/// it, and only the hosts on the list; everything else passes through untouched.
@Observable
final class HTTPSModel {
    enum Status: Equatable {
        case checking
        /// No certificate yet.
        case notSetUp
        /// The certificate exists, but macOS doesn't trust it, so nothing is decrypted.
        case notTrusted
        case trusted
        /// Busy, such as while macOS asks for the user's password.
        case working(String)
        case failed(String)
    }

    private(set) var status = Status.checking
    /// The hosts to decrypt, each switched on or off, and whether every other host is decrypted too.
    private(set) var hosts: DecryptedHosts
    var isShowingSetup = false

    /// A host to decrypt as soon as setup finishes.
    private var hostAfterSetup: String?
    private var root: RootIdentity?
    private var authority: CertificateAuthority?
    private let session: CaptureSession
    private let store: any RootStore = HTTPSModel.rootStore

    init(session: CaptureSession) {
        self.session = session
        let defaults = UserDefaults.standard
        let off = Set(defaults.stringArray(forKey: DefaultsKey.hostsNotDecrypted) ?? [])
        let entries = (defaults.stringArray(forKey: DefaultsKey.decryptedHosts) ?? []).compactMap { text in
            HostPattern(rawValue: text).map { DecryptedHosts.Entry($0, isOn: !off.contains($0.rawValue)) }
        }
        hosts = DecryptedHosts(
            entries: entries, includesEveryHost: defaults.bool(forKey: DefaultsKey.decryptsEveryHost))
        Task { await load() }
    }

    var isTrusted: Bool { status == .trusted }
    var hasCertificate: Bool { root != nil }

    /// When the certificate was made, and its name in Keychain Access.
    var certificateDetails: (created: Date, name: String)? {
        root.map { ($0.created, $0.name) }
    }

    /// Reqly's certificate, in DER, for devices and simulators to install. It's there once HTTPS
    /// is set up and macOS trusts it, since only then does Reqly decrypt.
    var certificateForDevices: [UInt8]? {
        guard isTrusted else { return nil }
        return try? root?.certificateDER
    }

    var isWorking: Bool {
        if case .working = status { true } else { false }
    }

    func isDecrypting(_ host: String) -> Bool {
        hosts.decrypts(host)
    }

    /// Decrypts a host from now on: switches its entry on, or adds one. Without a trusted
    /// certificate, it shows setup first.
    func decrypt(_ host: String) {
        guard isTrusted else {
            hostAfterSetup = host
            isShowingSetup = true
            return
        }
        guard !hosts.decrypts(host), let pattern = HostPattern(rawValue: host) else { return }
        if let index = hosts.entries.firstIndex(where: { $0.pattern == pattern }) {
            hosts.entries[index].isOn = true
        } else {
            hosts.entries.append(DecryptedHosts.Entry(pattern))
        }
        saveHosts()
    }

    /// Stops decrypting a host: switches its entry off, or adds one switched off, so a wildcard
    /// or Decrypt all hosts leaves it alone. It stays on the list, to switch on again.
    func stopDecrypting(_ host: String) {
        guard hosts.decrypts(host), let pattern = HostPattern(rawValue: host) else { return }
        if let index = hosts.entries.firstIndex(where: { $0.pattern == pattern }) {
            hosts.entries[index].isOn = false
        } else {
            hosts.entries.append(DecryptedHosts.Entry(pattern, isOn: false))
        }
        saveHosts()
    }

    /// Adds a host to the list, switched on, or says why it can't.
    func addHost(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let pattern = HostPattern(rawValue: text) else {
            return "“\(text)” isn't a host. Enter a name like api.example.com, or *.example.com for its subdomains."
        }
        guard !hosts.entries.contains(where: { $0.pattern == pattern }) else {
            return "\(pattern) is on the list already."
        }
        hosts.entries.append(DecryptedHosts.Entry(pattern))
        saveHosts()
        return nil
    }

    func removeHosts(_ patterns: Set<HostPattern>) {
        hosts.entries.removeAll { patterns.contains($0.pattern) }
        saveHosts()
    }

    func setDecrypts(_ isOn: Bool, _ pattern: HostPattern) {
        guard let index = hosts.entries.firstIndex(where: { $0.pattern == pattern }) else { return }
        hosts.entries[index].isOn = isOn
        saveHosts()
    }

    func setDecryptsEveryHost(_ isOn: Bool) {
        hosts.includesEveryHost = isOn
        saveHosts()
    }

    func toggleDecryption(_ host: String) {
        if isDecrypting(host) {
            stopDecrypting(host)
        } else {
            decrypt(host)
        }
    }

    func showSetup() {
        isShowingSetup = true
    }

    func cancelSetup() {
        hostAfterSetup = nil
        isShowingSetup = false
        if isWorking || status == .checking { return }
        if case .failed = status {
            status = root == nil ? .notSetUp : .notTrusted
        }
    }

    /// Creates the certificate if there isn't one, then asks macOS to trust it, which asks for
    /// the user's password.
    func setUp() async {
        let store = self.store
        do {
            status = .working("Creating Reqly's certificate…")
            let root = try await Task.detached {
                if let existing = try store.load() { return existing }
                let root = try RootIdentity.create()
                try store.save(root)
                return root
            }.value
            self.root = root
            status = .working("Waiting for you to allow it…")
            try await Task.detached { try store.trust(root) }.value
            refreshTrust()
            if isTrusted {
                isShowingSetup = false
                if let host = hostAfterSetup {
                    hostAfterSetup = nil
                    decrypt(host)
                }
            }
        } catch CertificateStoreError.cancelled {
            refreshTrust()
        } catch {
            status = .failed("Reqly couldn't set up HTTPS. \(Self.explain(error))")
        }
    }

    /// Asks whether to remove the certificate, then removes it.
    func removeAfterConfirming() {
        let alert = NSAlert()
        alert.messageText = "Remove Reqly's certificate?"
        alert.informativeText =
            isTrusted
            ? "Reqly stops decrypting HTTPS, and macOS no longer trusts its certificate. macOS asks for your password. You can set up HTTPS again at any time."
            : "Reqly removes its certificate and its key from your keychain. You can set up HTTPS again at any time."
        alert.addButton(withTitle: "Remove Certificate")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await remove() }
    }

    /// Removes the certificate, its trust setting and its key. macOS asks for the user's password.
    func remove() async {
        guard let root else { return }
        let store = self.store
        status = .working("Removing Reqly's certificate…")
        do {
            try await Task.detached { try store.remove(root) }.value
            self.root = nil
            refreshTrust()
        } catch CertificateStoreError.cancelled {
            refreshTrust()
        } catch {
            status = .failed("Reqly couldn't remove its certificate. \(Self.explain(error))")
        }
    }

    private func load() async {
        #if DEBUG
            if UserDefaults.standard.string(forKey: DefaultsKey.httpsStatus) == "notSetUp" {
                // As on a Mac without the certificate, leaving the keychain alone.
                refreshTrust()
                return
            }
        #endif
        let store = self.store
        root = try? await Task.detached { try store.load() }.value
        refreshTrust()
    }

    /// Reads whether macOS trusts the certificate, and decrypts only if it does.
    private func refreshTrust() {
        guard let root else {
            status = .notSetUp
            authority = nil
            applyToSession()
            return
        }
        status = store.isTrusted(root) ? .trusted : .notTrusted
        if isTrusted, authority == nil {
            authority = try? CertificateAuthority(root: root)
        } else if !isTrusted {
            authority = nil
        }
        applyToSession()
    }

    private func saveHosts() {
        let defaults = UserDefaults.standard
        defaults.set(hosts.entries.map(\.pattern.rawValue), forKey: DefaultsKey.decryptedHosts)
        defaults.set(hosts.entries.filter { !$0.isOn }.map(\.pattern.rawValue), forKey: DefaultsKey.hostsNotDecrypted)
        defaults.set(hosts.includesEveryHost, forKey: DefaultsKey.decryptsEveryHost)
        applyToSession()
    }

    private func applyToSession() {
        session.setDecryption(authority: authority, hosts: hosts)
    }

    private static func explain(_ error: any Error) -> String {
        if case CertificateStoreError.failed(let message) = error { return message }
        return error.localizedDescription
    }

    /// The login keychain, or in debug builds given `-rootFile path`, that file.
    private static var rootStore: any RootStore {
        #if DEBUG
            if let path = UserDefaults.standard.string(forKey: DefaultsKey.rootFile) {
                return FileRootStore(url: URL(filePath: path))
            }
        #endif
        return CertificateStore.standard
    }
}

#if DEBUG
    /// A certificate in a file, for test copies of Reqly. It's made there the first time, in the
    /// same form the Keychain keeps, and never goes near the Keychain or the Mac's trust settings.
    /// It counts as trusted, so a test copy decrypts with it and offers it to simulators and
    /// emulators, while macOS itself doesn't trust it.
    nonisolated struct FileRootStore: RootStore {
        let url: URL

        func load() throws -> RootIdentity? {
            if let data = try? Data(contentsOf: url) {
                return try CertificateStore.root(from: data)
            }
            let root = try RootIdentity.create()
            try save(root)
            return root
        }

        func save(_ root: RootIdentity) throws {
            try CertificateStore.data(for: root).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
        }

        func isTrusted(_ root: RootIdentity) -> Bool { true }

        func trust(_ root: RootIdentity) throws {}

        func remove(_ root: RootIdentity) throws {
            try? FileManager.default.removeItem(at: url)
        }
    }
#endif
