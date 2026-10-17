import Foundation
import ReqlyModel

/// Secrets, such as the upstream proxy's password and client certificates' private keys, in one
/// file, by name. On Windows the file is encrypted for your user account (DPAPI), so only you can
/// read it, as the Mac keeps them in your Keychain. A test run's file is plain instead.
public struct SecretFile: Sendable {
    public let file: URL
    /// Whether the file is encrypted for your user account. Only Windows can.
    public let isProtected: Bool

    public init(file: URL, isProtected: Bool) {
        self.file = file
        self.isProtected = isProtected
    }

    /// Why the secrets couldn't be kept, or read back.
    public struct Problem: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Each secret by its name, such as `Reqly Upstream Proxy/password`, or none if there's no file yet.
    public func load() throws -> [String: Data] {
        guard let stored = try? Data(contentsOf: file) else { return [:] }
        let plain = try isProtected ? Self.unprotect(stored) : stored
        return try JSONDecoder().decode([String: String].self, from: plain).compactMapValues {
            Data(base64Encoded: $0)
        }
    }

    public func save(_ secrets: [String: Data]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let plain = try encoder.encode(secrets.mapValues { $0.base64EncodedString() })
        let stored = try isProtected ? Self.protect(plain) : plain
        try FileReplacement.write(stored, to: file)
    }

    private static func protect(_ data: Data) throws -> Data {
        #if os(Windows)
            do {
                return try DataProtection.protect(data)
            } catch {
                throw Problem(message: "Windows couldn't encrypt them (error \(error.code)).")
            }
        #else
            throw Problem(message: "Only Windows can keep them encrypted for your user account.")
        #endif
    }

    private static func unprotect(_ data: Data) throws -> Data {
        #if os(Windows)
            do {
                return try DataProtection.unprotect(data)
            } catch {
                throw Problem(message: "Windows couldn't decrypt them (error \(error.code)).")
            }
        #else
            throw Problem(message: "Only Windows can keep them encrypted for your user account.")
        #endif
    }
}
