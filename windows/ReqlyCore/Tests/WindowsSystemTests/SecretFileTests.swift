import Foundation
import Testing
import WindowsSystem

@Suite struct SecretFileTests {
    let folder = URL.temporaryDirectory.appending(path: "ReqlySecretTests-\(UUID().uuidString)")

    @Test func keepsSecretsByName() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let secrets = SecretFile(file: folder.appending(path: "Secrets.json"), isProtected: false)
        #expect(try secrets.load().isEmpty)
        let kept = [
            "Reqly Upstream Proxy/password": Data("hunter2".utf8), "Reqly Client Certificate/A": Data([0, 1, 2]),
        ]
        try secrets.save(kept)
        #expect(try secrets.load() == kept)
        try secrets.save([:])
        #expect(try secrets.load().isEmpty)
    }

    #if os(Windows)
        /// Windows encrypts the file for this user. Nothing goes in any of Windows' stores.
        @Test func keepsThemEncryptedForYourUser() throws {
            defer { try? FileManager.default.removeItem(at: folder) }
            let secrets = SecretFile(file: folder.appending(path: "Secrets.dat"), isProtected: true)
            let kept = ["Reqly Upstream Proxy/password": Data("hunter2-hunter2".utf8)]
            try secrets.save(kept)
            let stored = try Data(contentsOf: secrets.file)
            #expect(stored.range(of: Data("hunter2".utf8)) == nil)
            #expect(stored.range(of: Data(kept.values.first!.base64EncodedString().utf8)) == nil)
            #expect(try secrets.load() == kept)
        }
    #endif
}
