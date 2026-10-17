#if os(Windows)
    import CertificateAuthority
    import Foundation
    import Testing
    import WindowsSystem

    @Suite struct WindowsRootStoreTests {
        /// Saves and reads a certificate, and only reads the trusted roots: it never trusts or
        /// removes anything, so the computer's certificate stores stay as they are.
        @Test func keepsTheCertificateEncryptedForYourUser() throws {
            let folder = URL.temporaryDirectory.appending(path: "ReqlyRootTests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = WindowsRootStore(file: folder.appending(path: "Root.dat"))
            #expect(try store.load() == nil)
            let root = try RootIdentity.create()
            try store.save(root)
            let saved = try Data(contentsOf: store.file)
            // Windows encrypted it: the private key isn't in the file as it is.
            #expect(saved.range(of: root.key.rawRepresentation) == nil)
            #expect(try store.load()?.certificateDER == root.certificateDER)
            // A certificate just made isn't among your trusted roots.
            #expect(!store.isTrusted(root))
        }
    }
#endif
