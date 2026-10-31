import CertificateAuthority
import CoreInterface
import Foundation
import LinuxDesktop
import LinuxSystem
import LinuxTrust
import ReqlyModel

/// HTTPS decryption, as the Mac app's HTTPS model keeps it: Reqly's certificate, and the hosts to
/// decrypt, which your settings keep. The session decrypts only while a place trusts the
/// certificate, and only the hosts on the list; everything else passes through untouched.
///
/// Linux has no one store that trusts the certificate, so the app adds it to each place itself,
/// with a LinuxRootStore made as the session's is, on the same files and keyring, then has the
/// session read it again. A test run's stand-in certificate counts as trusted, and no place on
/// the computer changes: the app never calls Linux's store then.
@MainActor
final class HTTPSModel {
    /// Where the certificate is kept.
    enum Store: Sendable {
        /// Linux's store, as the session's.
        case linux(LinuxRootStore)
        /// A test run's stand-in file.
        case standIn(FileRootStore)
    }

    /// How setting up went.
    struct SetupResult {
        /// What went wrong in each place that doesn't trust the certificate.
        var problems: [TrustPlace.Kind: TrustProblem] = [:]
        /// Why the certificate couldn't be made or kept, when it couldn't.
        var failure: String?
    }

    /// The app's HTTPS model, once the app has made it, for ``terminalCertificates()``. Reqly has
    /// one, as it has one session.
    private(set) static weak var current: HTTPSModel?

    private unowned let app: AppModel
    let store: Store
    /// The certificate's public files, beside its key's file: `Reqly CA.pem`, and the computer's
    /// list with it added, for the terminal and the fixes under Not Covered.
    let pemFile: URL
    let bundleFile: URL
    /// Whether HTTPS is set up, and the hosts to decrypt, as the session last said.
    private(set) var state: HTTPSState?
    /// Why the session couldn't say.
    private(set) var problem: String?
    /// Each place and whether it trusts the certificate, as last read. A test run's stand-in has
    /// none.
    private(set) var places: [TrustPlace] = []
    /// Where the key is kept, as last read, or nil before there's a certificate.
    private(set) var keyPlace: KeyPlace?
    /// Whether Reqly is setting up, trusting or removing the certificate.
    private(set) var isWorking = false
    /// The certificate, once read, so reading the places again asks the keyring nothing.
    private var root: RootIdentity?
    private var observers: [@MainActor () -> Void] = []

    init(app: AppModel) {
        self.app = app
        // The session's own file and helper, so both see the same certificate. A test run uses
        // only its files' names, for the fixes under Not Covered: the stand-in takes its place.
        let linux = SystemParts.linuxRootStore(file: app.folders.rootFile, trustHelper: app.options.trustHelper)
        pemFile = linux.pemFile
        bundleFile = linux.bundleFile
        store = app.options.rootStandIn.map { .standIn(FileRootStore(file: URL(filePath: $0))) } ?? .linux(linux)
        Self.current = self
    }

    var isStandIn: Bool {
        if case .standIn = store { true } else { false }
    }

    var hasCertificate: Bool { state.map { $0.status != .notSetUp } ?? false }

    /// The status in a word or two, or why it isn't known.
    var statusName: String {
        switch state?.status {
        case .trusted: "Decrypting"
        case .notTrusted: "Not trusted"
        case .notSetUp: "Not set up"
        case nil: problem ?? "Checking…"
        }
    }

    /// Where the key is kept, as Set Up HTTPS and Settings › HTTPS say it, or nil before there's
    /// one.
    var keyDescription: String? {
        switch store {
        case .standIn(let standIn):
            return hasCertificate ? "In this test run's file: \(standIn.file.path)" : nil
        case .linux(let store):
            switch keyPlace {
            case .keyring?: return "In your keyring"
            case .file?: return "In a file only you can read: \(HTTPSWidgets.shortPath(store.file))"
            case nil: return nil
            }
        }
    }

    /// The commands that add the certificate to the computer's list by hand, for when Reqly can't
    /// ask for an administrator's password itself, since its helper or pkexec is missing. Nil
    /// otherwise, before there's a certificate, and for a test run.
    var commandsToTrustByHand: String? {
        guard case .linux(let store) = store, hasCertificate, let reason = store.helper.unavailableReason,
            places.first(where: { $0.kind == .computer })?.status == .unavailable(reason)
        else { return nil }
        return ComputerList.commandsToAdd(pemFile: store.pemFile, uid: store.helper.uid)
    }

    /// The certificate's files for a terminal set up for Reqly, once HTTPS is set up and both are
    /// there. A test run's stand-in has none.
    var terminalCertificates: TerminalSetup.Certificates? {
        guard case .linux = store, hasCertificate,
            FileManager.default.fileExists(atPath: pemFile.path),
            FileManager.default.fileExists(atPath: bundleFile.path)
        else { return nil }
        return TerminalSetup.Certificates(bundle: bundleFile, root: pemFile)
    }

    /// Runs `body` after each change to HTTPS: its state, the places, or the work under way.
    func observe(_ body: @escaping @MainActor () -> Void) {
        observers.append(body)
    }

    private func changed() {
        for observer in observers {
            observer()
        }
        app.changed()
    }

    // MARK: - The certificate

    /// Hands the session the hosts you saved, and reads whether HTTPS is set up, as the session
    /// opens. With a certificate, it writes the terminal's copy of the computer's list again,
    /// since the computer's list changes with updates.
    func load() async {
        guard let session = app.session else { return }
        do {
            state = try await session.setDecryptedHosts(app.settings.decryptedHosts)
            problem = nil
        } catch {
            problem = error.message
        }
        changed()
        guard case .linux(let store) = store, hasCertificate else { return }
        let (root, failure) = await onOwnThread { () -> (RootIdentity?, String?) in
            guard let root = try? store.load() else { return (nil, nil) }
            do {
                try store.writeBundle(for: root)
                return (root, nil)
            } catch {
                return (root, error.localizedDescription)
            }
        }
        self.root = root
        if let failure {
            AppLog.write("couldn't write the terminal's list of certificates: \(failure)")
        }
    }

    /// Reads each place again, and where the key is, as Set Up HTTPS and Settings › HTTPS do each
    /// time they open: Chrome may have made its database since.
    func readPlaces() async {
        guard case .linux(let store) = store else { return }
        let known = root
        let hasCertificate = hasCertificate
        let read = await onOwnThread { () -> (RootIdentity?, [TrustPlace], KeyPlace?) in
            // The session read the certificate as it opened, so the keyring is open by now.
            let root = known ?? (hasCertificate ? try? store.load() : nil)
            return (root, store.places(for: root), store.keyPlace)
        }
        (root, places, keyPlace) = read
        changed()
    }

    /// What keeping the key in your keyring involves, for Set Up HTTPS to say before Linux asks,
    /// or nil when nothing will ask: for a key that's kept already, or a test run's stand-in.
    func keyringState() async -> KeyringState? {
        guard case .linux(let store) = store, keyPlace == nil else { return nil }
        return await onOwnThread { store.keyringState() }
    }

    /// Makes the certificate if there isn't one, keeps it, adds it to the places of `kinds`, then
    /// has the session read it again. Each step may wait: for the keyring's question, certutil, or
    /// an administrator's password, which `cancellation` stops waiting for.
    func setUp(trusting kinds: Set<TrustPlace.Kind>, cancellation: Cancellation) async -> SetupResult {
        isWorking = true
        changed()
        defer {
            isWorking = false
            changed()
        }
        var result = SetupResult()
        switch store {
        case .linux(let store):
            let made = await onOwnThread { () -> Result<(RootIdentity, [TrustPlace.Kind: TrustProblem]), Failure> in
                do {
                    let root = try store.load() ?? RootIdentity.create()
                    try store.save(root)
                    // Cancelled while the keyring asked: the certificate is kept, and trusted nowhere.
                    guard !cancellation.isCancelled else { return .success((root, [:])) }
                    return .success((root, store.trust(root, in: kinds, cancellation: cancellation)))
                } catch {
                    return .failure(Failure(error))
                }
            }
            switch made {
            case .success(let (root, problems)):
                self.root = root
                result.problems = problems
            case .failure(let failure):
                result.failure = "Reqly couldn't set up HTTPS. \(failure.reason)"
            }
        case .standIn(let standIn):
            let failure = await onOwnThread { () -> Failure? in
                do {
                    try standIn.save(try standIn.load() ?? RootIdentity.create())
                    return nil
                } catch {
                    return Failure(error)
                }
            }
            result.failure = failure.map { "Reqly couldn't set up HTTPS. \($0.reason)" }
        }
        await reload()
        return result
    }

    /// Adds the certificate to one place, as Trust… does, then has the session read it again.
    /// Returns what went wrong, if anything did.
    func trust(_ kind: TrustPlace.Kind) async -> TrustProblem? {
        guard case .linux(let store) = store, let root else { return nil }
        isWorking = true
        changed()
        defer {
            isWorking = false
            changed()
        }
        let problems = await onOwnThread { store.trust(root, in: [kind]) }
        await reload()
        return problems[kind]
    }

    /// Removes the certificate from every place, and its key, through the session, which stops
    /// decrypting. Returns what's left and why, when something is: the places that still trust
    /// it after you closed the password dialog, or what went wrong.
    func remove() async -> String? {
        guard let session = app.session else { return nil }
        isWorking = true
        changed()
        defer {
            isWorking = false
            changed()
        }
        var left: String?
        do {
            state = try await session.removeHTTPS()
        } catch {
            left = error.message
        }
        if !hasCertificate {
            root = nil
        }
        await readPlaces()
        if left == nil, hasCertificate {
            let trusting = places.filter { $0.status == .trusted }.map(\.name)
            left =
                trusting.isEmpty
                ? "You closed the password dialog, so Reqly kept its certificate."
                : "You closed the password dialog, so these still trust Reqly's certificate: "
                    + trusting.joined(separator: "; ") + "."
        }
        return left
    }

    /// Has the session read the certificate again, then reads the places.
    private func reload() async {
        if let session = app.session {
            state = await session.reloadHTTPS()
        }
        await readPlaces()
    }

    // MARK: - The hosts

    /// Adds a host or a wildcard to the list, switched on, or says why it can't, in the session's
    /// words.
    func addHost(_ text: String) async -> String? {
        guard let session = app.session else { return nil }
        do {
            apply(try await session.addDecryptedHost(text))
            return nil
        } catch {
            return error.message
        }
    }

    func removeHost(_ pattern: HostPattern) async {
        await change { session throws(Problem) in try await session.removeDecryptedHosts([pattern]) }
    }

    func setDecrypts(_ isOn: Bool, _ pattern: HostPattern) async {
        await change { session throws(Problem) in try await session.setHostDecrypted(pattern, isOn: isOn) }
    }

    func setDecryptsEveryHost(_ isOn: Bool) async {
        await change { session throws(Problem) in try await session.setDecryptsEveryHost(isOn) }
    }

    private func change(_ body: (SessionHost) async throws(Problem) -> HTTPSState) async {
        guard let session = app.session else { return }
        do {
            apply(try await body(session))
        } catch {
            AppLog.write("couldn't change the hosts to decrypt: \(error.message)")
        }
    }

    /// Shows the session's new list, and saves it in your settings, as Windows keeps it.
    private func apply(_ new: HTTPSState) {
        state = new
        changed()
        do {
            try app.changeSettings { $0.decryptedHosts = new.hosts }
        } catch {
            AppLog.write("couldn't save the hosts to decrypt: \(error.localizedDescription)")
        }
    }
}

/// Why the certificate couldn't be made, read or kept, in words.
private struct Failure: Error {
    var reason: String

    init(_ error: any Error) {
        reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
