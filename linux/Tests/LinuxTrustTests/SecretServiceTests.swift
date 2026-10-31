import Foundation
import Testing

@testable import LinuxTrust

/// Reqly's key in a real keyring: GNOME Keyring, on a D-Bus session of its own. Each test runs
/// itself again inside `dbus-run-session`, or with no session bus, in a home folder of its own, so
/// the session bus and keyring are the child's alone and nothing in this process's environment
/// changes.
@Suite struct SecretServiceTests {
    static let hasTools =
        ToolRun.find("dbus-run-session", in: ProcessInfo.processInfo.environment) != nil
        && ToolRun.find("gnome-keyring-daemon", in: ProcessInfo.processInfo.environment) != nil

    /// A login keyring, made and opened with a password, as a desktop login does.
    @Test(.enabled(if: hasTools, "Needs dbus-run-session and gnome-keyring-daemon."))
    func keepsTheKeyInAnOpenKeyring() throws {
        guard let marker = Self.inSession("unlocked") else {
            return try Self.runInSession("unlocked", test: "keepsTheKeyInAnOpenKeyring")
        }
        let keyring = SecretServiceKeyring(timeLimit: 20)
        #expect(keyring.state() == .ready)
        #expect(try keyring.load() == nil)
        let secret = Data((0..<200).map { UInt8($0) })
        try keyring.save(secret)
        #expect(try keyring.load() == secret)
        // Saving again replaces the one item.
        try keyring.save(Data("newer".utf8))
        #expect(try keyring.load() == Data("newer".utf8))
        try keyring.remove()
        #expect(try keyring.load() == nil)
        try keyring.remove()

        // The other secrets are an item of their own beside it.
        let others = SecretServiceKeyring(item: .secrets, timeLimit: 20)
        try keyring.save(secret)
        try others.save(Data("{}".utf8))
        #expect(try keyring.load() == secret)
        #expect(try others.load() == Data("{}".utf8))
        try others.remove()
        #expect(try others.load() == nil)
        #expect(try keyring.load() == secret)
        try keyring.remove()
        try Fixtures.withFolder { folder throws in
            let secrets = KeyringSecrets(
                file: folder.appending(path: "Secrets.json"), isProtected: true, keyring: others)
            try secrets.save(["Reqly Upstream Proxy/password": Data("hunter2".utf8)])
            #expect(!FileManager.default.fileExists(atPath: secrets.file.path))
            #expect(try secrets.load() == ["Reqly Upstream Proxy/password": Data("hunter2".utf8)])
            try secrets.save([:])
            #expect(try others.load() == nil)
        }

        // Through the storage: the keyring, and no file.
        try Fixtures.withFolder { folder throws in
            let storage = RootKeyStorage(file: folder.appending(path: "Certificate.dat"), keyring: keyring)
            #expect(try storage.save(secret) == RootKeyStorage.Saved(place: .keyring))
            #expect(!FileManager.default.fileExists(atPath: storage.file.path))
            #expect(try storage.load(from: .keyring) == secret)
            try storage.remove(from: .keyring)
            #expect(try keyring.load() == nil)
        }

        // Locked again, as at the next automatic login: unlocking asks, and here no dialog can
        // show, as if you closed it. That's never taken for no item.
        try keyring.save(secret)
        try Fixtures.withFolder { folder throws in
            let secrets = KeyringSecrets(
                file: folder.appending(path: "Secrets.json"), isProtected: true, keyring: others)
            try secrets.save(["Reqly Upstream Proxy/password": Data("hunter2".utf8)])
            let locked = try Fixtures.run(
                "/usr/bin/dbus-send",
                [
                    "--session", "--print-reply", "--dest=org.freedesktop.secrets", "/org/freedesktop/secrets",
                    "org.freedesktop.Secret.Service.Lock", "array:objpath:/org/freedesktop/secrets/collection/login",
                ], timeLimit: 20)
            try #require(locked.status == 0, "\(locked.errorText)")
            #expect(keyring.state() == .locked)
            #expect(throws: KeyringProblem.dismissed) { try keyring.load() }
            #expect(throws: KeyringProblem.dismissed) { try keyring.remove() }
            let storage = RootKeyStorage(file: folder.appending(path: "Certificate.dat"), keyring: keyring)
            #expect(throws: KeyringProblem.dismissed) { try storage.load(from: nil) }
            #expect(throws: KeyringProblem.dismissed) { try storage.remove(from: .keyring) }
            print(
                "The keyring, locked again, is \(keyring.state()), and loading says: \(Result { try keyring.load() })")

            let reopened = KeyringSecrets(file: secrets.file, isProtected: true, keyring: others)
            #expect(throws: KeyringSecrets.Problem.self) { try reopened.load() }
            // So a save, which would lose what it never read, changes nothing.
            #expect(throws: KeyringSecrets.Problem.self) { try reopened.save([:]) }
            #expect(!FileManager.default.fileExists(atPath: secrets.file.path))
        }
        try Data("passed".utf8).write(to: marker)
    }

    /// No default keyring, as after an automatic login: saving would ask for a new keyring's
    /// password, which the app explains first. Here no dialog can show, so the key goes to the file.
    @Test(.enabled(if: hasTools, "Needs dbus-run-session and gnome-keyring-daemon."))
    func fallsBackToTheFileWithoutADefaultKeyring() throws {
        guard let marker = Self.inSession("fresh") else {
            return try Self.runInSession("fresh", test: "fallsBackToTheFileWithoutADefaultKeyring")
        }
        let keyring = SecretServiceKeyring(timeLimit: 10)
        #expect(keyring.state() == .needsNewKeyring)
        try Fixtures.withFolder { folder throws in
            let storage = RootKeyStorage(file: folder.appending(path: "reqly/Certificate.dat"), keyring: keyring)
            let saved = try storage.save(Data("key".utf8))
            #expect(saved.place == .file)
            // No dialog can show here, so the keyring's question goes unanswered, as if closed.
            #expect(saved.keyringProblem == .dismissed)
            #expect(Fixtures.mode(storage.file) == 0o600)
            #expect(try storage.load(from: .file) == Data("key".utf8))
            print("The keyring said: \(saved.keyringProblem?.errorDescription ?? "nothing")")
        }
        try Data("passed".utf8).write(to: marker)
    }

    /// As under SSH with no session: the test runs itself again with no session bus.
    @Test func saysThereIsNoKeyringWithoutASessionBus() throws {
        guard let marker = Self.inSession("none") else {
            return try Self.runInSession("none", test: "saysThereIsNoKeyringWithoutASessionBus")
        }
        let keyring = SecretServiceKeyring(timeLimit: 10)
        guard case .unavailable(let reason) = keyring.state() else {
            Issue.record("A keyring answered without a session bus.")
            return
        }
        print("Without a session bus, the keyring's state says: \(reason)")
        #expect(throws: KeyringProblem.self) { try keyring.save(Data("key".utf8)) }
        try Fixtures.withFolder { folder throws in
            let storage = RootKeyStorage(file: folder.appending(path: "Certificate.dat"), keyring: keyring)
            #expect(try storage.save(Data("key".utf8)).place == .file)
            #expect(try storage.load(from: nil) == Data("key".utf8))
        }
        try Data("passed".utf8).write(to: marker)
    }

    // MARK: -

    /// The marker file to write once the test passes, when this process is the child running in
    /// a session of `kind`; otherwise `nil`.
    private static func inSession(_ kind: String) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["REQLY_KEYRING_SESSION"] == kind, let marker = environment["REQLY_KEYRING_MARKER"] else {
            return nil
        }
        return URL(filePath: marker)
    }

    /// Runs this test binary again, filtered to `test`, in a D-Bus session with GNOME Keyring, or
    /// with no session bus at all for `none`, and checks that the test passed there.
    private static func runInSession(_ kind: String, test: String) throws {
        try Fixtures.withFolder { folder throws in
            let home = folder.appending(path: "home")
            let runtime = folder.appending(path: "runtime")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
            chmod(runtime.path, 0o700)
            let marker = folder.appending(path: "passed")
            var environment = ProcessInfo.processInfo.environment.filter {
                !$0.key.hasPrefix("XDG_") && !$0.key.hasPrefix("DBUS_") && $0.key != "DISPLAY"
                    && $0.key != "WAYLAND_DISPLAY"
            }
            environment["HOME"] = home.path
            environment["XDG_RUNTIME_DIR"] = runtime.path
            environment["REQLY_KEYRING_SESSION"] = kind
            environment["REQLY_KEYRING_MARKER"] = marker.path
            // A login keyring opened with a password, as pam_gnome_keyring does at login; or none,
            // and D-Bus starts the keyring when it's first asked.
            let start = """
                if [ "$REQLY_KEYRING_SESSION" = unlocked ]; then
                    printf %s password | gnome-keyring-daemon --unlock --components=secrets >/dev/null || exit 90
                fi
                exec "$@"
                """
            let binary = try #require(Bundle.main.executablePath ?? CommandLine.arguments.first)
            let filter = [binary, "--testing-library", "swift-testing", "--filter", "SecretServiceTests/\(test)"]
            let ended =
                kind == "none"
                ? try Fixtures.run(binary, Array(filter.dropFirst()), environment: environment, timeLimit: 120)
                : try Fixtures.run(
                    "/usr/bin/dbus-run-session", ["--", "/bin/sh", "-c", start, "sh"] + filter,
                    environment: environment, timeLimit: 120)
            let said = String(decoding: ended.output + ended.errors, as: UTF8.self)
            if ended.status == 90 {
                withKnownIssue("GNOME Keyring couldn't start here, so this test was skipped:\n\(said)") {
                    Issue.record("No keyring.")
                }
                return
            }
            #expect(ended.status == 0, "The test failed in its D-Bus session:\n\(said)")
            #expect(FileManager.default.fileExists(atPath: marker.path), "The test didn't run in its session:\n\(said)")
            for line in said.split(separator: "\n") where line.hasPrefix("The keyring") {
                print(line)
            }
        }
    }
}
