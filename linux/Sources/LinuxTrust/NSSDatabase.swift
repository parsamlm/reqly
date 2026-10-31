import CertificateAuthority
import Foundation

/// One NSS database, the browsers' or a Firefox profile's, changed with NSS's certutil, from the
/// libnss3-tools package. Reqly finds its certificate there by its bytes, never by its name alone,
/// so it never mistakes another certificate with the same name for its own, or removes one.
struct NSSDatabase: Sendable {
    /// The database's folder, which holds cert9.db.
    var folder: URL
    /// certutil's path.
    var certutil: String
    var environment: [String: String]
    /// How long each certutil call may take, in seconds.
    var timeLimit: TimeInterval = 30

    /// Whether the database has Reqly's certificate, and trusts it to identify websites.
    enum Holding: Equatable {
        case trusted
        /// It's there, but not trusted for websites.
        case untrusted
        case absent
    }

    /// The name the certificate goes by in the database: the root's own, such as "Reqly CA
    /// 2026-10-04 00.10", with a dot for the colon, since certutil reads a colon as the end of a
    /// token's name.
    static func nickname(of root: RootIdentity) -> String {
        root.name.replacingOccurrences(of: ":", with: ".")
    }

    /// Makes an empty database, with no password, as Chrome makes one. Only you can open its
    /// folder.
    func create() throws(TrustFailure) {
        try PrivateFile.makeFolder(folder)
        let ended = try certutil(["-N", "-d", location, "--empty-password"])
        guard ended.status == 0 else { throw failure("make", ended) }
    }

    func holding(_ root: RootIdentity) throws(TrustFailure) -> Holding {
        let der = try Self.der(of: root)
        let name = Self.nickname(of: root)
        let found = try certificates(named: name)
        guard found.contains(der) else { return .absent }
        // Every certificate under that name shares its line, so if one of them is trusted for
        // websites, Reqly counts its own as trusted; trusting it again sets it anyway.
        let listed = try certutil(["-L", "-d", location])
        guard listed.status == 0 else { throw failure("read", listed) }
        // Each line is the name, then the trust flags for websites, email and code, such as "C,,".
        let trusted = String(decoding: listed.output, as: UTF8.self).split(separator: "\n").contains { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard let flags = line.split(whereSeparator: \.isWhitespace).last else { return false }
            let nickname = line.dropLast(flags.count).trimmingCharacters(in: .whitespaces)
            let websites = flags.split(separator: ",", omittingEmptySubsequences: false).first ?? ""
            return nickname == name && websites.contains("C")
        }
        return trusted ? .trusted : .untrusted
    }

    /// Adds the certificate, from its PEM file, trusted to identify websites, or trusts it when
    /// it's there already.
    func add(_ root: RootIdentity, pemFile: URL) throws(TrustFailure) {
        let ended = try certutil(["-A", "-d", location, "-n", Self.nickname(of: root), "-t", "C,,", "-i", pemFile.path])
        guard ended.status == 0 else { throw failure("add the certificate to", ended) }
        // A copy of the certificate under another name keeps that name, so Reqly can't find it.
        guard try holding(root) == .trusted else {
            throw TrustFailure(
                message: "certutil added Reqly's certificate to \(folder.path), but it isn't there under its own name.")
        }
    }

    /// Removes the certificate, if it's there. Returns whether it was. It leaves the database as
    /// it is when another certificate shares the name, since certutil removes by name.
    @discardableResult
    func remove(_ root: RootIdentity) throws(TrustFailure) -> Bool {
        let der = try Self.der(of: root)
        let name = Self.nickname(of: root)
        let found = try certificates(named: name)
        guard found.contains(der) else { return false }
        guard found.count == 1 else {
            throw TrustFailure(
                message: """
                    Another certificate in \(folder.path) is named \(name) too, so Reqly left its \
                    own there. Remove it with your browser's certificate settings.
                    """)
        }
        let ended = try certutil(["-D", "-d", location, "-n", name])
        guard ended.status == 0 else { throw failure("remove the certificate from", ended) }
        guard try !certificates(named: name).contains(der) else {
            throw TrustFailure(message: "certutil left Reqly's certificate in \(folder.path).")
        }
        return true
    }

    // MARK: -

    /// The database as certutil names it: its folder, in SQLite's format.
    private var location: String { "sql:\(folder.path)" }

    /// Each certificate filed under `name`, in DER: none, one, or more when they share a subject.
    private func certificates(named name: String) throws(TrustFailure) -> [[UInt8]] {
        let ended = try certutil(["-L", "-d", location, "-n", name, "-a"])
        guard ended.status == 0 else {
            // A database without the name, or a folder that has no database yet.
            if ended.errorText.contains("Could not find")
                || !FileManager.default.fileExists(
                    atPath: folder.appending(path: "cert9.db").path)
            {
                return []
            }
            throw failure("read", ended)
        }
        return PEM.certificates(in: String(decoding: ended.output, as: UTF8.self))
    }

    private func certutil(_ arguments: [String]) throws(TrustFailure) -> ToolRun.Ended {
        do {
            return try ToolRun(
                path: certutil, arguments: arguments, environment: ToolRun.withoutProxy(environment),
                timeLimit: timeLimit
            ).run()
        } catch .timedOut {
            throw TrustFailure(message: "certutil didn't finish with \(folder.path) in time.")
        } catch .notFound {
            throw TrustFailure(message: "certutil isn't installed. It's in the libnss3-tools package.")
        } catch {
            throw TrustFailure(message: "Reqly couldn't start certutil.")
        }
    }

    private func failure(_ action: String, _ ended: ToolRun.Ended) -> TrustFailure {
        let said = ended.errorText.isEmpty ? "it ended with status \(ended.status)" : ended.errorText
        return TrustFailure(message: "certutil couldn't \(action) \(folder.path): \(said)")
    }

    private static func der(of root: RootIdentity) throws(TrustFailure) -> [UInt8] {
        do {
            return try root.certificateDER
        } catch {
            throw TrustFailure(message: "Reqly couldn't encode its certificate.")
        }
    }
}

/// Certificates as PEM text, the form certutil, OpenSSL and the computer's list use.
enum PEM {
    static func encode(_ der: [UInt8]) -> String {
        let lines = Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(lines)\n-----END CERTIFICATE-----\n"
    }

    /// Each certificate in `text`, in DER, in order. Anything else in it is skipped.
    static func certificates(in text: String) -> [[UInt8]] {
        var found: [[UInt8]] = []
        var body: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line == "-----BEGIN CERTIFICATE-----" {
                body = ""
            } else if line == "-----END CERTIFICATE-----" {
                if let body, let der = Data(base64Encoded: body) {
                    found.append([UInt8](der))
                }
                body = nil
            } else if body != nil {
                body! += line
            }
        }
        return found
    }
}
