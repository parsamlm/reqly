import Capture
import CertificateAuthority
import Dispatch
import Foundation
import Synchronization
import Testing
import TrafficStore

@testable import CoreInterface

@Suite(.timeLimit(.minutes(1))) struct HTTPSHostTests {
    /// A certificate removed outside the app, then made again, signs with an authority of its own,
    /// never with the one before, which nothing trusts any more.
    @Test func signsWithTheCertificateItReadLast() async throws {
        let folder = SessionAPITests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SwappedRootStore()
        let first = try RootIdentity.create()
        store.keep(first)
        let traffic = try TrafficStore.newSession(in: folder.appending(path: "Sessions"))
        defer { traffic.discard() }
        let https = HTTPSHost(store: store, capture: CaptureSession(store: traffic))
        await https.startLoading()
        #expect(await https.currentState().status == .trusted)
        #expect(try await https.authority?.root.certificateDER == first.certificateDER)

        let second = try RootIdentity.create()
        store.keep(second)
        #expect(await https.reload().status == .trusted)
        #expect(try await https.authority?.root.certificateDER == second.certificateDER)
    }

    /// The session opens while the certificate is still being read, as while your keyring waits
    /// to be unlocked, and its HTTPS calls wait for it. What kept it from being read is said.
    @Test func opensWithoutWaitingForTheCertificate() async throws {
        let folder = SessionAPITests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SlowRootStore()
        let system = SystemParts(rootStore: { _ in store }, secrets: { file, _ in PlainSecrets(file: file) })
        let host = try await SessionHost.open(
            OpenOptions(
                sessionsFolder: folder.appending(path: "Sessions").path, findsApps: false,
                rootFile: folder.appending(path: "Certificate.dat").path),
            system: system, events: { _ in })
        // Open, though the store hasn't answered: had the session waited for it, it would still be
        // opening, until the time limit.
        store.answer(with: .failure(CertificateStoreError.failed("The keyring stayed locked.")))
        let unread = try await host.https()
        #expect(unread.status == .notSetUp && unread.readProblem == "The keyring stayed locked.")

        // Read again, once it can be.
        let root = try RootIdentity.create()
        store.answer(with: .success(root))
        let read = await host.reloadHTTPS()
        #expect(read.status == .trusted && read.certificateName == root.name && read.readProblem == nil)
        await host.close()
    }
}

/// A store whose certificate the app swaps behind the session's back, trusted each time.
private final class SwappedRootStore: RootStore {
    private let kept = Mutex<RootIdentity?>(nil)

    func keep(_ root: RootIdentity) {
        kept.withLock { $0 = root }
    }

    func load() throws -> RootIdentity? { kept.withLock { $0 } }
    func save(_ root: RootIdentity) throws { keep(root) }
    func isTrusted(_ root: RootIdentity) -> Bool { true }
    func trust(_ root: RootIdentity) throws {}
    func remove(_ root: RootIdentity) throws { kept.withLock { $0 = nil } }
}

/// A store that doesn't answer until it's told what to say, as a locked keyring waits for you.
private final class SlowRootStore: RootStore {
    private let answers = Mutex<[Result<RootIdentity?, any Error>]>([])
    private let given = DispatchSemaphore(value: 0)

    /// What the next reading says, once it's asked.
    func answer(with answer: Result<RootIdentity?, any Error>) {
        answers.withLock { $0.append(answer) }
        given.signal()
    }

    func load() throws -> RootIdentity? {
        given.wait()
        return try answers.withLock { $0.removeFirst() }.get()
    }

    func save(_ root: RootIdentity) throws {}
    func isTrusted(_ root: RootIdentity) -> Bool { true }
    func trust(_ root: RootIdentity) throws {}
    func remove(_ root: RootIdentity) throws {}
}
