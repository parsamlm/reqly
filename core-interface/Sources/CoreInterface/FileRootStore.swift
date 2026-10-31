import CertificateAuthority
import Foundation
import ReqlyModel

/// A root in a plain file, for test runs, made there the first time HTTPS is set up. It counts as
/// trusted, so a test run decrypts with it, while the computer itself never trusts it: it never
/// goes near the system's certificate stores.
public struct FileRootStore: RootStore {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func load() throws -> RootIdentity? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try RootIdentity(serialized: data)
    }

    public func save(_ root: RootIdentity) throws {
        try FileReplacement.write(root.serialized(), to: file)
    }

    public func isTrusted(_ root: RootIdentity) -> Bool { true }

    public func trust(_ root: RootIdentity) throws {}

    public func remove(_ root: RootIdentity) throws {
        try? FileManager.default.removeItem(at: file)
    }
}
