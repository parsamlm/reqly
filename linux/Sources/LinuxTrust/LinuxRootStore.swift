import CertificateAuthority
import Foundation

/// Reqly's root on Linux. Its certificate and key stay in your keyring, or in a file only you can
/// read when there's no keyring to use. Apps trust the certificate in three places, which Reqly
/// adds it to: the browsers' NSS databases and Firefox's profiles, through certutil, and the
/// computer's list, through the helper, which asks for an administrator's password. Chromium's
/// own list, where you import it for the Chromium snap, is yours alone to change: Reqly only
/// reads it, to say when it still trusts the certificate.
///
/// Next to the key's file, Reqly keeps the certificate itself, `Reqly CA.pem`, for the terminal and
/// devices; the computer's list with it added, `ca-certificates.crt`, for the terminal; and a
/// record of where it added the certificate, so removing it finds each place.
///
/// Every call may run tools, wait for the keyring, or wait for you to type a password, so call
/// them off the main thread.
public struct LinuxRootStore: RootStore {
    /// The key's file, `Certificate.dat`, used when the keyring isn't. Its folder holds the rest.
    public let file: URL
    public let keys: RootKeyStorage
    public let locations: TrustLocations
    public var helper: TrustHelper
    /// The environment certutil is found in, through `PATH`, and tools run with.
    public let environment: [String: String]
    /// The computer's list, which only tests change.
    public let computerBundle: String

    /// The store that keeps its file at `file`, normally `~/.local/share/reqly/Certificate.dat`.
    /// `helper` is the helper's path, for development runs; by default, the installed one.
    /// `pkexec` is pkexec's, which only tests change.
    public init(
        file: URL, keyring: (any Keyring)? = SecretServiceKeyring(), helper: String? = nil,
        pkexec: String = TrustHelper.pkexecPath, environment: [String: String] = ProcessInfo.processInfo.environment,
        uid: UInt32 = getuid(), computerBundle: String = ComputerList.bundle
    ) {
        self.file = file
        keys = RootKeyStorage(file: file, keyring: keyring)
        locations = TrustLocations(environment: environment)
        self.helper = TrustHelper(
            path: helper ?? TrustHelper.installedPath, pkexec: pkexec, environment: environment, uid: uid)
        self.environment = environment
        self.computerBundle = computerBundle
    }

    /// The certificate, without its key, which anyone may read.
    public var pemFile: URL { file.deletingLastPathComponent().appending(path: "Reqly CA.pem") }
    /// The computer's list with the certificate added, for tools in the terminal that take one
    /// list in place of the computer's.
    public var bundleFile: URL { file.deletingLastPathComponent().appending(path: "ca-certificates.crt") }
    var recordFile: URL { file.deletingLastPathComponent().appending(path: "CertificateRecord.json") }

    // MARK: RootStore

    /// The root, or `nil` before there's one. Throws ``KeyGone`` when the record says your
    /// keyring has the key and the keyring has no such item, as after you reset your keyring.
    public func load() throws -> RootIdentity? {
        let record = readRecord()
        guard let data = try keys.load(from: record?.key) else {
            if record?.key == .keyring, keys.keyring != nil { throw KeyGone() }
            return nil
        }
        return try RootIdentity(serialized: data)
    }

    /// Reqly's key isn't in your keyring any more, though the record says it's there, so its
    /// certificate can't be used. Setting up HTTPS again makes a new one, and ``save(_:)`` takes
    /// the old one out of the browsers' databases and Firefox's profiles first.
    public struct KeyGone: LocalizedError, Equatable {
        public init() {}

        public var errorDescription: String? {
            "Reqly's key isn't in your keyring any more, so Reqly can't use its certificate. Set up HTTPS "
                + "again to make a new one."
        }
    }

    /// Whether ``load()`` would throw ``KeyGone``: the record says your keyring has the key, and
    /// the keyring has no such item. It asks the keyring only whether it has the item, which asks
    /// you nothing. A keyring that doesn't answer, or isn't there, doesn't count as without it.
    public func isKeyGone() -> Bool {
        guard let record = readRecord(), record.key == .keyring, keys.keyring != nil else { return false }
        return !isKept(record, askingTheKeyring: true)
    }

    /// Whether the key isn't where the record says any more: gone from your keyring, as
    /// ``isKeyGone()`` says, or its file gone, as when you deleted it. The places then show the
    /// certificate as an old one, and a new setup keeps a new key, as at the first. It asks you
    /// nothing.
    public func isKeyMissing() -> Bool {
        switch readRecord()?.key {
        case .keyring?: isKeyGone()
        case .file?: !FileManager.default.fileExists(atPath: file.path)
        case nil: false
        }
    }

    /// Keeps the key, in the keyring if it can, and writes the certificate next to it. A root
    /// that's kept already stays where it is, so saving it again asks nothing. A new root, made
    /// because the old one's key was gone, takes the old one's place: the old certificate leaves
    /// the databases it was added to first, since only its record says where they are.
    public func save(_ root: RootIdentity) throws {
        let certificate = try Self.base64(root)
        var record = readRecord()
        if let old = record, old.certificate != certificate {
            removeFromDatabases(old)
        }
        if record?.certificate != certificate || !isKept(record) {
            let saved = try keys.save(try root.serialized())
            if record?.certificate != certificate {
                record = Record(certificate: certificate)
            }
            record?.key = saved.place
        }
        record?.name = root.name
        try writeRecord(record)
        try writeCertificate(root)
    }

    /// Whether at least one place trusts the certificate, which is when Reqly decrypts. Chromium's
    /// own list counts too, once you imported the certificate there, as Settings › HTTPS says to
    /// for the Chromium snap, and so does the snap's NSS database, for a certificate you added
    /// there yourself.
    public func isTrusted(_ root: RootIdentity) -> Bool {
        guard let der = try? root.certificateDER else { return false }
        if ComputerList.contains(der, bundle: computerBundle) { return true }
        if let certutil = certutil {
            let folders =
                locations.browserDatabases() + locations.firefoxProfiles()
                + locations.chromiumSnapDatabasesOutOfReach()
            if folders.contains(where: { (try? database($0, certutil).holding(root)) == .trusted }) { return true }
        }
        return locations.chromiumStores().contains { (try? $0.trust(of: der)) == .trusted }
    }

    /// Adds the certificate to every place that doesn't trust it yet, which is what Set Up HTTPS
    /// does by default. The computer's list asks for an administrator's password. It throws only
    /// when no place trusts the certificate afterwards: `cancelled` when you closed the password
    /// dialog. ``places(for:)`` shows how each place went.
    public func trust(_ root: RootIdentity) throws {
        let waiting = places(for: root).filter { $0.status == .notTrusted }.map(\.kind)
        let problems = trust(root, in: Set(waiting))
        guard !isTrusted(root) else { return }
        if problems.values.contains(where: \.isDeclined) { throw CertificateStoreError.cancelled }
        let reasons =
            problems.values.compactMap(\.errorDescription)
            + places(for: root).compactMap { place in
                if case .unavailable(let reason) = place.status { reason } else { nil }
            }
        throw CertificateStoreError.failed(
            reasons.isEmpty ? "No place on this computer could trust it." : reasons.joined(separator: " "))
    }

    /// Removes the certificate from every place it was added to or is found in, then its key,
    /// its files and the record. If you close the password dialog, or a place can't be changed,
    /// the key and the record stay, so removing it again picks up where this left off.
    public func remove(_ root: RootIdentity) throws {
        try remove(root, cancellation: nil)
    }

    // MARK: Places

    /// Each place, and whether it trusts `root`. Without one, as when your keyring stayed locked
    /// or its key has gone, whether it trusts the certificate the record is about, which is the
    /// old one once its key has gone; and with no record either, what it would take.
    public func places(for root: RootIdentity?) -> [TrustPlace] {
        if let root {
            return places(der: try? root.certificateDER, trusted: .trusted) { database throws(TrustFailure) in
                try database.holding(root)
            }
        }
        guard let record = readRecord(), let der = Data(base64Encoded: record.certificate).map(Array.init) else {
            return places(der: nil, trusted: .trusted, holding: nil)
        }
        // A keyring that's only locked still has the key; without it, the certificate is an old one.
        return places(der: der, trusted: isKept(record, askingTheKeyring: true) ? .trusted : .trustsOldCertificate) {
            database throws(TrustFailure) in try database.holdingReqlyCertificate(der: der)
        }
    }

    /// Each place, and whether it trusts the certificate `der`, which `holding` finds in a
    /// database, saying `trusted` where it does; or what it would take, with no certificate.
    private func places(
        der: [UInt8]?, trusted: TrustPlace.Status,
        holding: ((NSSDatabase) throws(TrustFailure) -> NSSDatabase.Holding)?
    ) -> [TrustPlace] {
        let certutil = certutil
        func status(of folders: [URL]) -> TrustPlace.Status {
            guard let certutil else { return .unavailable(Self.needsCertutil) }
            guard let holding else { return .notTrusted }
            var holdings: [NSSDatabase.Holding] = []
            var failure: String?
            for folder in folders {
                do {
                    holdings.append(try holding(database(folder, certutil)))
                } catch {
                    failure = error.message
                }
            }
            if holdings.isEmpty, let failure { return .unavailable(failure) }
            // An old certificate is still trusted wherever one database has it.
            if trusted == .trustsOldCertificate { return holdings.contains(.trusted) ? trusted : .notTrusted }
            return failure == nil && holdings.allSatisfy { $0 == .trusted } ? trusted : .notTrusted
        }

        // With no database, as before Chrome or another browser built on it first runs, there's
        // nothing to trust it in yet. Settings › HTTPS looks again each time it opens.
        let browsers = locations.browserDatabases()
        let browserStatus: TrustPlace.Status = browsers.isEmpty ? .notFound : status(of: browsers)
        let profiles = locations.firefoxProfiles()
        let firefoxStatus: TrustPlace.Status = profiles.isEmpty ? .notFound : status(of: profiles)
        let computerStatus: TrustPlace.Status
        if let der, ComputerList.contains(der, bundle: computerBundle) {
            computerStatus = trusted
        } else if !FileManager.default.fileExists(atPath: computerBundle) {
            computerStatus = .unavailable("This computer keeps no list of certificates at \(computerBundle).")
        } else if let reason = helper.unavailableReason {
            computerStatus = .unavailable(reason)
        } else {
            computerStatus = .notTrusted
        }
        return [
            TrustPlace(kind: .browsers, status: browserStatus, locations: browsers),
            TrustPlace(kind: .firefox, status: firefoxStatus, locations: profiles),
            TrustPlace(kind: .computer, status: computerStatus, locations: [URL(filePath: computerBundle)]),
        ]
    }

    /// Adds the certificate to the places of `kinds` only, as Settings › HTTPS's Trust… does,
    /// and returns what went wrong in each that didn't work. The computer's list asks for an
    /// administrator's password, and
    /// waits as long as the dialog is open, unless `cancellation` stops it.
    public func trust(
        _ root: RootIdentity, in kinds: Set<TrustPlace.Kind>, cancellation: Cancellation? = nil
    ) -> [TrustPlace.Kind: TrustProblem] {
        var problems: [TrustPlace.Kind: TrustProblem] = [:]
        let certificate: String
        do {
            certificate = try Self.base64(root)
            try writeCertificate(root)
        } catch {
            return Dictionary(uniqueKeysWithValues: kinds.map { ($0, .failed(error.localizedDescription)) })
        }
        var record = recordAbout(certificate)
        record.name = root.name
        defer { try? writeRecord(record) }

        func add(to folders: [URL], _ certutil: String) -> TrustProblem? {
            var failures: [String] = []
            for folder in folders {
                do {
                    try database(folder, certutil).add(root, pemFile: pemFile)
                    if !record.databases.contains(folder.path) { record.databases.append(folder.path) }
                } catch {
                    failures.append(error.message)
                }
            }
            return failures.isEmpty ? nil : .failed(failures.joined(separator: " "))
        }

        if kinds.contains(.browsers) {
            let folders = locations.browserDatabases()
            if folders.isEmpty {
                problems[.browsers] = .unavailable(
                    "No browser built on Chrome has a certificate database yet. Open one once, then come back.")
            } else if let certutil {
                problems[.browsers] = add(to: folders, certutil)
            } else {
                problems[.browsers] = .unavailable(Self.needsCertutil)
            }
        }
        if kinds.contains(.firefox) {
            let profiles = locations.firefoxProfiles()
            if profiles.isEmpty {
                problems[.firefox] = .unavailable("Firefox has no profile yet. Open Firefox once, then come back.")
            } else if let certutil {
                problems[.firefox] = add(to: profiles, certutil)
            } else {
                problems[.firefox] = .unavailable(Self.needsCertutil)
            }
        }
        if kinds.contains(.computer), let der = try? root.certificateDER {
            if ComputerList.contains(der, bundle: computerBundle) {
                record.computer = true
            } else {
                do {
                    try helper.add(pem: PEM.encode(der), pemFile: pemFile, cancellation: cancellation)
                    record.computer = true
                } catch {
                    problems[.computer] = error
                }
            }
        }
        try? writeBundle(for: root)
        return problems
    }

    /// Removes the certificate as ``remove(_:)`` does, and stops waiting for the password dialog
    /// when `cancellation` says so, as when you close it.
    public func remove(_ root: RootIdentity, cancellation: Cancellation?) throws {
        try remove(certificate: try Self.base64(root), der: try root.certificateDER, cancellation: cancellation) {
            database throws(TrustFailure) in try database.remove(root)
        }
    }

    /// Removes the certificate the record is about, as ``remove(_:)`` does, when its key has gone
    /// and ``load()`` throws ``KeyGone``: from each database by its bytes alone, whatever name it
    /// has there. Returns whether there was a record.
    @discardableResult
    public func removeWithoutKey(cancellation: Cancellation? = nil) throws -> Bool {
        guard let record = readRecord(), let der = Data(base64Encoded: record.certificate).map(Array.init) else {
            return false
        }
        try remove(certificate: record.certificate, der: der, cancellation: cancellation) {
            database throws(TrustFailure) in try database.removeReqlyCertificate(der: der)
        }
        return true
    }

    private func remove(
        certificate: String, der: [UInt8], cancellation: Cancellation?,
        removingFrom: (NSSDatabase) throws(TrustFailure) -> Bool
    ) throws {
        var record = recordAbout(certificate)
        var left: [String] = []

        // The databases it was added to, and any others it's found in now, such as the Chromium
        // snap's, where you may have added it yourself. Chromium's own list, where you import it
        // for the snap, is Chromium's alone to change: see chromiumCopies(of:).
        var seen = Set<String>()
        let folders =
            (record.databases.map { URL(filePath: $0, directoryHint: .isDirectory) }
            + locations.browserDatabases() + locations.firefoxProfiles() + locations.chromiumSnapDatabasesOutOfReach())
            .filter { seen.insert($0.path).inserted }
        for folder in folders {
            let recorded = record.databases.contains(folder.path)
            guard FileManager.default.fileExists(atPath: folder.path) else {
                record.databases.removeAll { $0 == folder.path }
                continue
            }
            guard let certutil else {
                if recorded { left.append("\(folder.path): \(Self.needsCertutil)") }
                continue
            }
            do {
                _ = try removingFrom(database(folder, certutil))
                record.databases.removeAll { $0 == folder.path }
            } catch {
                // A database Reqly never added to, which certutil can't read, doesn't hold up the rest.
                if recorded { left.append(error.message) }
            }
        }

        let computerFile = ComputerList.certificateFile(uid: helper.uid)
        if ComputerList.contains(der, bundle: computerBundle) || FileManager.default.fileExists(atPath: computerFile) {
            do {
                try helper.remove(cancellation: cancellation)
                record.computer = false
            } catch let problem where problem.isDeclined {
                try writeRecord(record)
                throw CertificateStoreError.cancelled
            } catch {
                left.append(Self.removalProblem(error, uid: helper.uid))
            }
        } else {
            record.computer = false
        }

        // Only the reasons: whoever shows them says what didn't go.
        guard left.isEmpty else {
            try writeRecord(record)
            throw CertificateStoreError.failed(left.joined(separator: " "))
        }
        try keys.remove(from: record.key)
        for file in [pemFile, bundleFile, recordFile] {
            try PrivateFile.remove(file)
        }
        // The folder too, once nothing else of Reqly's is in it.
        rmdir(file.deletingLastPathComponent().path)
    }

    /// Takes the certificate `old` is about out of the databases it lists, and the ones found
    /// now, by its bytes, as far as certutil can: a certificate nothing can remove once its record
    /// has gone mustn't stay trusted.
    private func removeFromDatabases(_ old: Record) {
        guard let certutil, let der = Data(base64Encoded: old.certificate).map(Array.init) else { return }
        var seen = Set<String>()
        let folders =
            (old.databases.map { URL(filePath: $0, directoryHint: .isDirectory) } + locations.browserDatabases()
            + locations.firefoxProfiles() + locations.chromiumSnapDatabasesOutOfReach())
            .filter { seen.insert($0.path).inserted && FileManager.default.fileExists(atPath: $0.path) }
        for folder in folders {
            _ = try? database(folder, certutil).removeReqlyCertificate(der: der)
        }
    }

    // MARK: Files

    /// Where the key is kept, for Settings › HTTPS, or `nil` before there's one.
    public var keyPlace: KeyPlace? { readRecord()?.key }

    /// The certificate the record is about, in DER, with its name, such as "Reqly CA 2026-11-01
    /// 16:37", as for one whose key has gone; or nil when there's no record. A record an earlier
    /// Reqly wrote has no name.
    public var recordedCertificate: (der: [UInt8], name: String?)? {
        guard let record = readRecord(), let der = Data(base64Encoded: record.certificate) else { return nil }
        return ([UInt8](der), record.name)
    }

    /// What Chromium's and Google Chrome's own lists say of the certificate `der`: the ones that
    /// trust it, after you imported it there, which Reqly can't change or remove, and the ones it
    /// couldn't read. Reqly reads each from a copy, and never changes Chromium's files.
    public func chromiumCopies(of der: [UInt8]) -> ChromiumCopies {
        var copies = ChromiumCopies()
        for store in locations.chromiumStores() {
            do {
                if try store.trust(of: der) == .trusted {
                    copies.trusting.append(store)
                }
            } catch {
                copies.unread.append(store)
            }
        }
        return copies
    }

    /// What saving in the keyring involves, for Set Up HTTPS to explain before the first save,
    /// such as a question about a new keyring's password.
    public func keyringState() -> KeyringState {
        keys.keyringState()
    }

    /// Writes ``bundleFile``: the computer's list, with the certificate added unless it's there
    /// already. The app writes it again at each launch, since the computer's list changes with
    /// updates.
    public func writeBundle(for root: RootIdentity) throws {
        let der = try root.certificateDER
        var text = (try? String(contentsOfFile: computerBundle, encoding: .utf8)) ?? ""
        if !PEM.certificates(in: text).contains(der) {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += PEM.encode(der)
        }
        try PrivateFile.write(Data(text.utf8), to: bundleFile, mode: 0o644)
    }

    // MARK: -

    /// Where the certificate was added, and where its key is.
    struct Record: Codable, Equatable {
        /// The certificate it's about, in DER, base64.
        var certificate: String
        /// The certificate's name, for what Reqly says of it once its key has gone. Records an
        /// earlier Reqly wrote have none.
        var name: String?
        var key: KeyPlace?
        /// The NSS databases it was added to: the browsers' and Firefox profiles'.
        var databases: [String] = []
        /// Whether it was added to the computer's list.
        var computer = false
    }

    /// The record about `certificate`, or a new one when the record is about another, or there's
    /// none.
    private func recordAbout(_ certificate: String) -> Record {
        readRecord().flatMap { $0.certificate == certificate ? $0 : nil } ?? Record(certificate: certificate)
    }

    func readRecord() -> Record? {
        guard let data = try? Data(contentsOf: recordFile) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func writeRecord(_ record: Record?) throws {
        guard let record else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try PrivateFile.write(try encoder.encode(record), to: recordFile, mode: 0o600)
    }

    /// Whether the key the record names is still where it says, as far as can be told without
    /// asking the keyring, or, `askingTheKeyring`, by asking it only whether it has the item, which
    /// asks you nothing. A keyring that doesn't answer counts as having it.
    private func isKept(_ record: Record?, askingTheKeyring: Bool = false) -> Bool {
        switch record?.key {
        case .keyring: !askingTheKeyring || keys.keyring.map { (try? $0.isKept()) != false } ?? false
        case .file: FileManager.default.fileExists(atPath: file.path)
        case nil: false
        }
    }

    private func writeCertificate(_ root: RootIdentity) throws {
        try PrivateFile.write(Data(PEM.encode(try root.certificateDER).utf8), to: pemFile, mode: 0o644)
    }

    private var certutil: String? { ToolRun.find("certutil", in: environment) }

    private func database(_ folder: URL, _ certutil: String) -> NSSDatabase {
        NSSDatabase(folder: folder, certutil: certutil, environment: environment)
    }

    private static let needsCertutil = "Needs the libnss3-tools package, which has certutil."

    /// What kept the certificate in the computer's list, with the commands that take it out by
    /// hand when Reqly can't ask for the password at all: with no helper or pkexec, or where it
    /// isn't allowed, as over SSH. With no password dialog, the problem has them already.
    static func removalProblem(_ problem: TrustProblem, uid: UInt32) -> String {
        let reason = problem.errorDescription ?? ""
        switch problem {
        case .unavailable, .notAllowed:
            return reason + " To take it out yourself, run these in a terminal, then remove it again:\n"
                + ComputerList.commandsToRemove(uid: uid)
        case .cancelled, .refused, .noPasswordDialog, .failed:
            return reason
        }
    }

    private static func base64(_ root: RootIdentity) throws -> String {
        Data(try root.certificateDER).base64EncodedString()
    }
}
