import CertificateAuthority
import Foundation
import Testing

@testable import LinuxTrust

/// Adding, finding and removing Reqly's certificate in NSS databases with certutil, by its bytes:
/// a decoy with the same name, from a root made in the same minute, is never taken for it.
@Suite(.enabled(if: Fixtures.certutil != nil, "Needs certutil, from libnss3-tools."))
struct NSSDatabaseTests {
    func database(_ folder: URL) throws -> NSSDatabase {
        NSSDatabase(
            folder: folder, certutil: try #require(Fixtures.certutil),
            environment: ProcessInfo.processInfo.environment)
    }

    func writePEM(_ root: RootIdentity, in folder: URL) throws -> URL {
        let file = folder.appending(path: "\(UUID().uuidString).pem")
        try PEM.encode(try root.certificateDER).write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test func makesAnEmptyDatabaseOnlyYouCanOpen() throws {
        try Fixtures.withFolder { folder throws in
            let database = try database(folder.appending(path: "pki/nssdb"))
            try database.create()
            #expect(FileManager.default.fileExists(atPath: database.folder.appending(path: "cert9.db").path))
            #expect(Fixtures.mode(database.folder) == 0o700)
            #expect(try database.holding(try Fixtures.root()) == .absent)
        }
    }

    @Test func addsFindsAndRemovesTheRoot() throws {
        try Fixtures.withFolder { folder throws in
            let database = try database(folder.appending(path: "nssdb"))
            try database.create()
            let root = try Fixtures.root()
            // Its name has a colon, which certutil would read as a token's name.
            #expect(root.name.contains(":"))
            try database.add(root, pemFile: try writePEM(root, in: folder))
            #expect(try database.holding(root) == .trusted)
            // Adding it again changes nothing.
            try database.add(root, pemFile: try writePEM(root, in: folder))
            #expect(try database.holding(root) == .trusted)
            #expect(try database.remove(root))
            #expect(try database.holding(root) == .absent)
            #expect(try !database.remove(root))
        }
    }

    /// certutil adds to a folder with no database yet, as Chrome's ~/.pki/nssdb may be.
    @Test func addsToAFolderWithNoDatabaseYet() throws {
        try Fixtures.withFolder { folder throws in
            let nssdb = folder.appending(path: ".pki/nssdb")
            try FileManager.default.createDirectory(at: nssdb, withIntermediateDirectories: true)
            let database = try database(nssdb)
            let root = try Fixtures.root()
            #expect(try database.holding(root) == .absent)
            try database.add(root, pemFile: try writePEM(root, in: folder))
            #expect(try database.holding(root) == .trusted)
        }
    }

    @Test func neverTakesADecoyWithTheSameNameForTheRoot() throws {
        try Fixtures.withFolder { folder throws in
            let database = try database(folder.appending(path: "nssdb"))
            try database.create()
            let root = try Fixtures.root(minute: 1)
            let decoy = try Fixtures.root(minute: 1)
            #expect(root.name == decoy.name)
            try database.add(decoy, pemFile: try writePEM(decoy, in: folder))

            #expect(try database.holding(root) == .absent)
            #expect(try !database.remove(root))
            #expect(try database.holding(decoy) == .trusted)

            // With both there under one name, certutil can't remove just one, so Reqly leaves both.
            try database.add(root, pemFile: try writePEM(root, in: folder))
            #expect(try database.holding(root) == .trusted)
            #expect(throws: TrustFailure.self) { try database.remove(root) }
            #expect(try database.holding(root) == .trusted)
            #expect(try database.holding(decoy) == .trusted)
        }
    }

    /// A copy that's there but not trusted for websites isn't trusted, and adding it trusts it.
    @Test func seesARootThatIsThereButNotTrusted() throws {
        try Fixtures.withFolder { folder throws in
            let database = try database(folder.appending(path: "nssdb"))
            try database.create()
            let root = try Fixtures.root(minute: 2)
            let pem = try writePEM(root, in: folder)
            let ended = try Fixtures.run(
                try #require(Fixtures.certutil),
                [
                    "-A", "-d", "sql:\(database.folder.path)", "-n", NSSDatabase.nickname(of: root), "-t", ",,", "-i",
                    pem.path,
                ])
            #expect(ended.status == 0, "\(ended.errorText)")
            #expect(try database.holding(root) == .untrusted)
            try database.add(root, pemFile: pem)
            #expect(try database.holding(root) == .trusted)
        }
    }

    @Test func readsCertificatesInPEM() throws {
        let one = try Fixtures.root(minute: 3)
        let two = try Fixtures.root(minute: 4)
        let text = "junk\n" + PEM.encode(try one.certificateDER) + "more junk\r\n" + PEM.encode(try two.certificateDER)
        #expect(PEM.certificates(in: text) == [try one.certificateDER, try two.certificateDER])
        #expect(PEM.certificates(in: "-----BEGIN CERTIFICATE-----\nnot base64!\n-----END CERTIFICATE-----\n").isEmpty)
    }
}
