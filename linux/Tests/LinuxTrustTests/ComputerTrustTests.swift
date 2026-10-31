import CertificateAuthority
import Foundation
import Testing

@testable import LinuxTrust

/// The helper, reqly-trust, run as root against this container's own list of certificates, and
/// the whole store, which runs it through a stand-in for pkexec. One at a time, since they all
/// change the same list.
@Suite(
    .serialized,
    .enabled(
        if: Fixtures.isRoot && FileManager.default.fileExists(atPath: "/usr/sbin/update-ca-certificates"),
        "Needs root and update-ca-certificates, as in the container."))
struct ComputerTrustTests {
    /// The helper in the repository, beside the tests.
    static let helperPath = URL(filePath: #filePath).deletingLastPathComponent().appending(
        path: "../../packaging/reqly-trust"
    ).standardizedFileURL.path

    func helper(_ arguments: [String], uid: String? = "4242", input: String = "") throws -> ToolRun.Ended {
        var environment = ["PATH": "/usr/bin:/bin"]
        environment["PKEXEC_UID"] = uid
        return try Fixtures.run("/bin/sh", [Self.helperPath] + arguments, environment: environment, input: input)
    }

    func bundleCount() throws -> Int {
        try String(contentsOfFile: ComputerList.bundle, encoding: .utf8).components(
            separatedBy: "-----BEGIN CERTIFICATE-----"
        ).count - 1
    }

    // MARK: The helper

    @Test func addsTheRootForOneAccountAndRemovesIt() throws {
        let root = try Fixtures.root(minute: 20)
        let der = try root.certificateDER
        let before = try bundleCount()
        let added = try helper(["add"], input: PEM.encode(der))
        #expect(added.status == 0, "\(added.errorText)")
        #expect(FileManager.default.fileExists(atPath: ComputerList.linkedFile(uid: 4242)))
        #expect(Fixtures.mode(URL(filePath: ComputerList.certificateFile(uid: 4242))) == 0o644)
        #expect(ComputerList.contains(der))
        #expect(try bundleCount() == before + 1)

        // Another account's root stays apart, and stays when the first one's goes.
        let other = try Fixtures.root(minute: 21)
        #expect(try helper(["add"], uid: "4243", input: PEM.encode(try other.certificateDER)).status == 0)
        let removed = try helper(["remove"])
        #expect(removed.status == 0, "\(removed.errorText)")
        #expect(!ComputerList.contains(der))
        #expect(ComputerList.contains(try other.certificateDER))
        #expect(!FileManager.default.fileExists(atPath: ComputerList.linkedFile(uid: 4242)))
        #expect(try helper(["remove"], uid: "4243").status == 0)
        #expect(try bundleCount() == before)
        #expect(!FileManager.default.fileExists(atPath: "/usr/local/share/ca-certificates/reqly"))
        // Removing what isn't there is fine.
        #expect(try helper(["remove"]).status == 0)
    }

    @Test func refusesWhatIsNotOneReqlyRoot() throws {
        let before = try bundleCount()
        let root = PEM.encode(try Fixtures.root(minute: 22).certificateDER)
        let refused = [
            "two certificates": root + PEM.encode(try Fixtures.root(minute: 23).certificateDER),
            "not a CA": try Fixtures.openSSLCertificate(
                subject: "/CN=Reqly CA 2026-10-31 12:00/O=Reqly", extensions: ["basicConstraints=critical,CA:FALSE"]),
            "another organization": try Fixtures.openSSLCertificate(
                subject: "/CN=Reqly CA 2026-10-31 12:00/O=Someone", extensions: ["basicConstraints=critical,CA:TRUE"]),
            "another name": try Fixtures.openSSLCertificate(
                subject: "/CN=Totally Real CA/O=Reqly", extensions: ["basicConstraints=critical,CA:TRUE"]),
            "a key with it": root + "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n",
            "nothing": "",
            "not PEM": "hello\n",
        ]
        for (what, input) in refused {
            let ended = try helper(["add"], input: input)
            #expect(ended.status == 1, "It took \(what): \(ended.errorText)")
            #expect(ended.errorText.hasPrefix("reqly-trust: "), "\(what): \(ended.errorText)")
        }
        #expect(!FileManager.default.fileExists(atPath: ComputerList.certificateFile(uid: 4242)))
        #expect(try bundleCount() == before)
    }

    @Test func needsAnAccountAndACommand() throws {
        let root = PEM.encode(try Fixtures.root(minute: 24).certificateDER)
        for uid in [nil, "", "1000; rm -rf /", "-1", "../0"] {
            #expect(try helper(["add"], uid: uid, input: root).status == 2, "It took the account \(uid ?? "nil").")
        }
        #expect(try helper([]).status == 2)
        #expect(try helper(["trust"]).status == 2)
        #expect(try helper(["add", "/home/you/Reqly CA.pem"], input: root).status == 1)
        #expect(!FileManager.default.fileExists(atPath: "/usr/local/share/ca-certificates/reqly"))
    }

    /// Java's keystore hook, as ca-certificates-java installs it, hears about the removal as
    /// update-ca-certificates would tell it.
    @Test func tellsTheHooksAboutTheRemoval() throws {
        let hooks = URL(filePath: "/etc/ca-certificates/update.d")
        let hook = hooks.appending(path: "reqly-test-hook")
        let heard = URL(filePath: NSTemporaryDirectory()).appending(path: "reqly-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try Fixtures.script("#!/bin/sh\ncat >> \(heard.path)\n", at: hook)
        defer {
            try? FileManager.default.removeItem(at: hook)
            try? FileManager.default.removeItem(at: heard)
        }
        #expect(try helper(["add"], input: PEM.encode(try Fixtures.root(minute: 25).certificateDER)).status == 0)
        try? FileManager.default.removeItem(at: heard)
        #expect(try helper(["remove"]).status == 0)
        let lines = try String(contentsOf: heard, encoding: .utf8).split(separator: "\n")
        #expect(lines.contains("-/etc/ssl/certs/reqly-ca-4242.pem"))
    }

    // MARK: Uninstalling

    /// The package's postrm, beside the helper.
    static let postrmPath = URL(filePath: helperPath).deletingLastPathComponent().appending(path: "postrm").path

    /// Removing the package takes every account's root out of the computer's list, and tells the
    /// hooks, as the helper does for one account. An upgrade leaves them.
    @Test func uninstallingTakesEveryAccountsRootOut() throws {
        let hooks = URL(filePath: "/etc/ca-certificates/update.d")
        let hook = hooks.appending(path: "reqly-test-hook")
        let heard = URL(filePath: NSTemporaryDirectory()).appending(path: "reqly-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try Fixtures.script("#!/bin/sh\ncat >> \(heard.path)\n", at: hook)
        defer {
            try? FileManager.default.removeItem(at: hook)
            try? FileManager.default.removeItem(at: heard)
        }
        let before = try bundleCount()
        let roots = [try Fixtures.root(minute: 26), try Fixtures.root(minute: 27)]
        for (root, uid) in zip(roots, ["4245", "4246"]) {
            #expect(try helper(["add"], uid: uid, input: PEM.encode(try root.certificateDER)).status == 0)
        }
        let postrm = { (argument: String) in
            try Fixtures.run("/bin/sh", [Self.postrmPath, argument], environment: ["PATH": "/usr/bin:/bin"])
        }
        #expect(try postrm("upgrade").status == 0)
        #expect(try bundleCount() == before + 2)

        try? FileManager.default.removeItem(at: heard)
        let removed = try postrm("remove")
        #expect(removed.status == 0, "\(removed.errorText)")
        #expect(removed.errorText.isEmpty, "\(removed.errorText)")
        for root in roots {
            #expect(!ComputerList.contains(try root.certificateDER))
        }
        #expect(try bundleCount() == before)
        #expect(!FileManager.default.fileExists(atPath: "/usr/local/share/ca-certificates/reqly"))
        let lines = try String(contentsOf: heard, encoding: .utf8).split(separator: "\n")
        #expect(
            lines.contains("-/etc/ssl/certs/reqly-ca-4245.pem") && lines.contains("-/etc/ssl/certs/reqly-ca-4246.pem"))
        // With nothing left, it does nothing.
        #expect(try postrm("purge").status == 0)
    }

    // MARK: The store

    /// A home folder, a keyring in memory, and a pkexec that runs the helper as root for account
    /// 4244, as polkit would once you typed the password.
    func withStore(
        pkexec: String = "export PKEXEC_UID=4244\nexec /bin/sh \"$@\"",
        _ body: (LinuxRootStore, FakeKeyring, URL) throws -> Void
    ) throws {
        try Fixtures.withFolder { home throws in
            let bin = home.appending(path: "bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try Fixtures.script("#!/bin/sh\n\(pkexec)\n", at: bin.appending(path: "pkexec"))
            let environment = [
                "HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin", "http_proxy": "http://127.0.0.1:9",
            ]
            let keyring = FakeKeyring()
            let store = LinuxRootStore(
                file: home.appending(path: ".local/share/reqly/Certificate.dat"), keyring: keyring,
                helper: Self.helperPath, pkexec: bin.appending(path: "pkexec").path, environment: environment,
                uid: 4244)
            defer { _ = try? helper(["remove"], uid: "4244") }
            try body(store, keyring, home)
        }
    }

    @Test func setsUpHTTPSEverywhereAndRemovesItAgain() throws {
        try withStore { store, keyring, home in
            // A Firefox profile that's been opened, and one that hasn't.
            let firefox = home.appending(path: ".config/mozilla/firefox")
            try FileManager.default.createDirectory(
                at: firefox.appending(path: "a.default-esr"), withIntermediateDirectories: true)
            try "[Profile0]\nIsRelative=1\nPath=a.default-esr\n[Profile1]\nIsRelative=1\nPath=b.new\n".write(
                to: firefox.appending(path: "profiles.ini"), atomically: true, encoding: .utf8)
            let profile = NSSDatabase(
                folder: firefox.appending(path: "a.default-esr"), certutil: try #require(Fixtures.certutil),
                environment: [:])
            try profile.create()
            // And the database Chrome made when it first ran.
            let chrome = home.appending(path: ".local/share/pki/nssdb")
            try NSSDatabase(folder: chrome, certutil: try #require(Fixtures.certutil), environment: [:]).create()

            #expect(try store.load() == nil)
            let before = store.places(for: nil)
            #expect(before.map(\.kind) == [.browsers, .firefox, .computer])
            #expect(before.map(\.status) == [.notTrusted, .notTrusted, .notTrusted])
            #expect(before[0].locations.map(\.path) == [chrome.path] && before[1].locations.count == 1)
            #expect(before[2].needsPassword && !before[0].needsPassword)

            // As Set Up HTTPS does it.
            let root = try Fixtures.root(minute: 30)
            try store.save(root)
            #expect(store.keyPlace == .keyring)
            #expect(Fixtures.mode(store.pemFile) == 0o644)
            #expect(try store.load().map { try $0.certificateDER } == root.certificateDER)
            #expect(!store.isTrusted(root))
            try store.trust(root)
            #expect(store.isTrusted(root))
            let after = store.places(for: root)
            #expect(after.map(\.status) == [.trusted, .trusted, .trusted])
            #expect(ComputerList.contains(try root.certificateDER))
            #expect(ComputerList.contains(try root.certificateDER, bundle: store.bundleFile.path))
            let record = try #require(store.readRecord())
            #expect(record.computer && record.databases.count == 2 && record.key == .keyring)
            // Saving again, as Set Up HTTPS does with a root it has, asks the keyring nothing.
            try store.save(root)
            #expect(keyring.saves.withLock { $0 } == 1)

            try store.remove(root)
            #expect(!store.isTrusted(root))
            #expect(store.places(for: root).map(\.status) == [.notTrusted, .notTrusted, .notTrusted])
            #expect(try store.load() == nil)
            #expect(keyring.secret.withLock { $0 } == nil)
            for file in [store.pemFile, store.bundleFile, store.recordFile] {
                #expect(!FileManager.default.fileExists(atPath: file.path), "\(file.path) is left.")
            }
        }
    }

    /// Closing the password dialog while removing keeps the key and the record, so Reqly still
    /// decrypts where the certificate is trusted, and removing again finishes the job.
    @Test func keepsWhatIsLeftWhenThePasswordIsDeclined() throws {
        try withStore { store, keyring, home in
            let root = try Fixtures.root(minute: 31)
            try store.save(root)
            try store.trust(root)
            #expect(ComputerList.contains(try root.certificateDER))

            // From now on, pkexec's dialog is closed each time.
            try Fixtures.script("#!/bin/sh\nexit 126\n", at: home.appending(path: "bin/pkexec"))
            #expect(throws: CertificateStoreError.cancelled) { try store.remove(root) }
            #expect(try store.load() != nil)
            let record = try #require(store.readRecord())
            #expect(record.computer && record.databases.isEmpty)
            #expect(store.places(for: root).map(\.status) == [.notFound, .notFound, .trusted])
            #expect(store.isTrusted(root))

            try Fixtures.script(
                "#!/bin/sh\nexport PKEXEC_UID=4244\nexec /bin/sh \"$@\"\n", at: home.appending(path: "bin/pkexec"))
            try store.remove(root)
            #expect(!ComputerList.contains(try root.certificateDER))
            #expect(try store.load() == nil)
        }
    }

    /// Declining the password while setting up still trusts the browsers, so Reqly decrypts there.
    @Test func setUpWithoutThePasswordStillTrustsTheBrowsers() throws {
        try withStore(pkexec: "exit 126") { store, _, home in
            try NSSDatabase(
                folder: home.appending(path: ".pki/nssdb"), certutil: try #require(Fixtures.certutil), environment: [:]
            ).create()
            let root = try Fixtures.root(minute: 32)
            try store.save(root)
            try store.trust(root)
            #expect(store.isTrusted(root))
            #expect(store.places(for: root).map(\.status) == [.trusted, .notFound, .notTrusted])
            let problems = store.trust(root, in: [.computer])
            #expect(problems == [.computer: .cancelled])
        }
    }

    /// With no certutil and no password, nothing trusts the root, and trusting it says so.
    @Test func withoutCertutilOrThePasswordNothingTrustsIt() throws {
        try withStore(pkexec: "exit 126") { store, _, home in
            // A PATH with the helper's tools, but no certutil.
            let bin = home.appending(path: "bin")
            for tool in ["sh", "cat", "openssl"] {
                symlink("/usr/bin/\(tool)", bin.appending(path: tool).path)
            }
            // A browser's database, which needs certutil.
            try FileManager.default.createDirectory(
                at: home.appending(path: ".pki/nssdb"), withIntermediateDirectories: true)
            let bare = LinuxRootStore(
                file: store.file, keyring: FakeKeyring(), helper: Self.helperPath, pkexec: store.helper.pkexec,
                environment: ["HOME": home.path, "PATH": bin.path], uid: 4244)
            let root = try Fixtures.root(minute: 33)
            try bare.save(root)
            #expect(
                bare.places(for: root)[0].status == .unavailable("Needs the libnss3-tools package, which has certutil.")
            )
            #expect(throws: CertificateStoreError.cancelled) { try bare.trust(root) }
            #expect(!bare.isTrusted(root))
        }
    }

    /// A key file others can read is refused, and the store says why instead of making a new root.
    @Test func refusesAnOpenKeyFile() throws {
        try withStore { store, _, _ in
            let fileOnly = LinuxRootStore(
                file: store.file, keyring: nil, helper: Self.helperPath, pkexec: store.helper.pkexec,
                environment: store.environment, uid: 4244)
            let root = try Fixtures.root(minute: 34)
            try fileOnly.save(root)
            #expect(fileOnly.keyPlace == .file)
            #expect(Fixtures.mode(store.file) == 0o600)
            #expect(Fixtures.mode(store.file.deletingLastPathComponent()) == 0o700)
            chmod(store.file.path, 0o644)
            #expect(throws: TrustFailure.self) { try fileOnly.load() }
        }
    }
}
