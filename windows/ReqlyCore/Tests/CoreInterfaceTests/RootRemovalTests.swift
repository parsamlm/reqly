import CertificateAuthority
import CoreInterface
import Foundation
import Testing
import WindowsSystem

/// Uninstalling removes Reqly's certificate. These use a stand-in file, as test runs do, so the
/// computer's certificate stores are never touched.
@Suite struct RootRemovalTests {
    @Test func removesTheCertificateAndItsKey() throws {
        let file = URL.temporaryDirectory.appending(path: "ReqlyRootRemoval-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: file) }
        try FileRootStore(file: file).save(RootIdentity.create())
        let path = file.withUnsafeFileSystemRepresentation { String(cString: $0!) }

        #expect(RootRemoval.remove(rootFile: path, standIn: true) == .removed)
        #expect(!FileManager.default.fileExists(atPath: path))
        // Uninstalling again, or after HTTPS was never set up, finds nothing to remove.
        #expect(RootRemoval.remove(rootFile: path, standIn: true) == .nothing)
    }

    @Test func keepsItWhenYouSayNo() {
        #expect(RootRemoval.remove(from: Declining()) == .declined)
    }

    @Test func saysWhenItCantReadTheCertificate() throws {
        let file = URL.temporaryDirectory.appending(path: "ReqlyRootRemoval-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not a certificate".utf8).write(to: file)
        #expect(RootRemoval.remove(from: FileRootStore(file: file)) == .failed)
    }
}

/// A store whose user says no to removing the certificate, as Windows' prompt allows.
private struct Declining: RootStore {
    func load() throws -> RootIdentity? { try RootIdentity.create() }
    func save(_ root: RootIdentity) throws {}
    func isTrusted(_ root: RootIdentity) -> Bool { true }
    func trust(_ root: RootIdentity) throws {}
    func remove(_ root: RootIdentity) throws { throw CertificateStoreError.cancelled }
}
