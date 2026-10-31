import CertificateAuthority
import Foundation
import Testing

@testable import LinuxTrust

/// What the trust tests share: scratch folders, roots, certificates made with OpenSSL, and a way
/// to run a command and read what it said.
enum Fixtures {
    /// A new empty folder, deleted when `body` returns.
    static func withFolder<Result>(_ body: (URL) throws -> Result) throws -> Result {
        let folder = URL(filePath: NSTemporaryDirectory()).appending(path: "reqly-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try body(folder)
    }

    /// A root made at a fixed minute, so two of them share their name and differ only in their
    /// key and serial number, as a decoy would.
    static func root(minute: Int = 0) throws -> RootIdentity {
        try RootIdentity.create(
            now: Date(timeIntervalSince1970: 1_793_448_000 + Double(minute) * 60),
            timeZone: TimeZone(identifier: "UTC")!)
    }

    /// The PEM of a certificate OpenSSL makes for `subject`, such as `/CN=Reqly CA 1/O=Reqly`,
    /// with `extensions` such as `basicConstraints=critical,CA:TRUE`.
    static func openSSLCertificate(subject: String, extensions: [String]) throws -> String {
        try withFolder { folder throws in
            let pem = folder.appending(path: "certificate.pem")
            var arguments = [
                "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-keyout",
                folder.appending(path: "key.pem").path, "-out", pem.path, "-days", "30", "-subj", subject,
            ]
            for item in extensions {
                arguments += ["-addext", item]
            }
            let ended = try run("/usr/bin/openssl", arguments)
            #expect(ended.status == 0, "openssl: \(ended.errorText)")
            return try String(contentsOf: pem, encoding: .utf8)
        }
    }

    /// Runs `path` with `arguments`, waits for it, and returns how it ended.
    static func run(
        _ path: String, _ arguments: [String], environment: [String: String]? = nil, input: String = "",
        timeLimit: TimeInterval = 120
    ) throws -> ToolRun.Ended {
        try ToolRun(
            path: path, arguments: arguments, environment: environment ?? ProcessInfo.processInfo.environment,
            input: Data(input.utf8), timeLimit: timeLimit
        ).run()
    }

    /// A file's mode bits, such as 0o600.
    static func mode(_ url: URL) -> mode_t {
        var status = stat()
        guard stat(url.path, &status) == 0 else { return 0 }
        return status.st_mode & 0o7777
    }

    /// Writes an executable shell script.
    static func script(_ text: String, at url: URL) throws {
        try Data(text.utf8).write(to: url)
        chmod(url.path, 0o755)
    }

    static var certutil: String? { ToolRun.find("certutil", in: ProcessInfo.processInfo.environment) }
    static var isRoot: Bool { geteuid() == 0 }
}
