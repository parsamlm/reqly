import Foundation
import Testing

@testable import LinuxTrust

/// The key's file, when there's no keyring: only you can read it, and Reqly won't read one that
/// others can. The tests run as root, which can read any file, so they check modes, not access.
@Suite struct KeyFileTests {
    @Test func writesAFileOnlyYouCanReadInAFolderOnlyYouCanOpen() throws {
        try Fixtures.withFolder { folder throws in
            let file = folder.appending(path: "share/reqly/Certificate.dat")
            let previous = umask(0o022)
            defer { umask(previous) }
            try PrivateFile.write(Data("key".utf8), to: file, mode: 0o600)
            #expect(Fixtures.mode(file) == 0o600)
            #expect(Fixtures.mode(file.deletingLastPathComponent()) == 0o700)
            #expect(try PrivateFile.readOwn(file) == Data("key".utf8))
            // Nothing's left behind, such as the new file before it took the old one's place.
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == [
                    "Certificate.dat"
                ])
        }
    }

    /// The terminal's list: the computer's with the certificate added, which anyone may read, as
    /// the computer's is. Written again, as at the next launch, it doesn't grow.
    @Test func writesTheTerminalsListForEveryoneToRead() throws {
        try Fixtures.withFolder { folder throws in
            let computer = folder.appending(path: "ca-certificates.crt")
            try Data("-----BEGIN CERTIFICATE-----\nSYSTEM\n-----END CERTIFICATE-----".utf8).write(to: computer)
            let store = LinuxRootStore(
                file: folder.appending(path: "reqly/Certificate.dat"), keyring: nil, computerBundle: computer.path)
            let root = try Fixtures.root(minute: 40)
            let previous = umask(0o077)
            defer { umask(previous) }
            try store.writeBundle(for: root)
            let written = try String(contentsOf: store.bundleFile, encoding: .utf8)
            #expect(written.hasPrefix("-----BEGIN CERTIFICATE-----\nSYSTEM\n-----END CERTIFICATE-----\n"))
            #expect(ComputerList.contains(try root.certificateDER, bundle: store.bundleFile.path))
            #expect(Fixtures.mode(store.bundleFile) == 0o644)
            try store.writeBundle(for: root)
            #expect(try String(contentsOf: store.bundleFile, encoding: .utf8) == written)
        }
    }

    @Test func replacingTheFileKeepsItsMode() throws {
        try Fixtures.withFolder { folder throws in
            let file = folder.appending(path: "Certificate.dat")
            try PrivateFile.write(Data("first".utf8), to: file, mode: 0o600)
            // A umask that would leave the file open to everyone, and one that would close a
            // public file, change nothing.
            let previous = umask(0)
            try PrivateFile.write(Data("second".utf8), to: file, mode: 0o600)
            umask(0o077)
            try PrivateFile.write(Data("public".utf8), to: folder.appending(path: "Reqly CA.pem"), mode: 0o644)
            umask(previous)
            #expect(Fixtures.mode(file) == 0o600)
            #expect(Fixtures.mode(folder.appending(path: "Reqly CA.pem")) == 0o644)
            #expect(try PrivateFile.readOwn(file) == Data("second".utf8))
        }
    }

    @Test func makesAnOpenFolderPrivate() throws {
        try Fixtures.withFolder { folder throws in
            let reqly = folder.appending(path: "reqly")
            try FileManager.default.createDirectory(at: reqly, withIntermediateDirectories: true)
            chmod(reqly.path, 0o755)
            try PrivateFile.write(Data("key".utf8), to: reqly.appending(path: "Certificate.dat"), mode: 0o600)
            #expect(Fixtures.mode(reqly) == 0o700)
        }
    }

    @Test func refusesAFileOthersCanRead() throws {
        try Fixtures.withFolder { folder throws in
            let file = folder.appending(path: "Certificate.dat")
            try PrivateFile.write(Data("key".utf8), to: file, mode: 0o600)
            for mode: mode_t in [0o640, 0o604, 0o620, 0o644] {
                chmod(file.path, mode)
                #expect {
                    try PrivateFile.readOwn(file)
                } throws: { error in
                    (error as? TrustFailure)?.message.contains("others can read") == true
                }
            }
            chmod(file.path, 0o400)
            #expect(try PrivateFile.readOwn(file) == Data("key".utf8))
        }
    }

    @Test(.enabled(if: Fixtures.isRoot, "Giving a file to another account needs root."))
    func refusesAFileAnotherAccountOwns() throws {
        try Fixtures.withFolder { folder throws in
            let file = folder.appending(path: "Certificate.dat")
            try PrivateFile.write(Data("key".utf8), to: file, mode: 0o600)
            #expect(chown(file.path, 4321, 4321) == 0)
            #expect {
                try PrivateFile.readOwn(file)
            } throws: { error in
                (error as? TrustFailure)?.message.contains("another account owns") == true
            }
        }
    }

    @Test func refusesALinkAndSaysThereIsNoFileWhenThereIsNone() throws {
        try Fixtures.withFolder { folder throws in
            let file = folder.appending(path: "Certificate.dat")
            #expect(try PrivateFile.readOwn(file) == nil)
            let target = folder.appending(path: "elsewhere")
            try PrivateFile.write(Data("key".utf8), to: target, mode: 0o600)
            #expect(symlink(target.path, file.path) == 0)
            #expect(throws: TrustFailure.self) { try PrivateFile.readOwn(file) }
        }
    }
}
