import Foundation

/// A cookie an app sent, from a `Cookie` header.
public struct RequestCookie: Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A cookie a server set, from a `Set-Cookie` header (RFC 6265).
public struct ResponseCookie: Hashable, Sendable {
    public var name: String
    public var value: String
    public var domain: String?
    public var path: String?
    /// The `Expires` date as the server wrote it.
    public var expires: String?
    /// Seconds until it expires, from `Max-Age`.
    public var maxAge: Int?
    public var isSecure = false
    public var isHTTPOnly = false
    public var sameSite: String?
    public var isPartitioned = false

    /// `nil` when the header doesn't start with a name and a value, such as `id=42`.
    public init?(setCookie header: String) {
        let parts = header.split(separator: ";", omittingEmptySubsequences: false)
        guard let pair = parts.first, let equals = pair.firstIndex(of: "=") else { return nil }
        let name = pair[..<equals].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        self.name = name
        value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        for attribute in parts.dropFirst() {
            let pieces = attribute.split(separator: "=", maxSplits: 1)
            guard let key = pieces.first?.trimmingCharacters(in: .whitespaces).lowercased() else { continue }
            let value = pieces.count > 1 ? pieces[1].trimmingCharacters(in: .whitespaces) : nil
            switch key {
            case "domain": domain = value
            case "path": path = value
            case "expires": expires = value
            case "max-age": maxAge = value.flatMap { Int($0) }
            case "secure": isSecure = true
            case "httponly": isHTTPOnly = true
            case "samesite": sameSite = value
            case "partitioned": isPartitioned = true
            default: break
            }
        }
    }

    /// When it expires, if the `Expires` date is in one of the forms servers use.
    public var expiryDate: Date? {
        guard let expires else { return nil }
        for format in Self.dateFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: expires) {
                return date
            }
        }
        return nil
    }

    /// RFC 1123, RFC 850 and its four-digit variant, and C's asctime.
    private static let dateFormats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE, dd-MMM-yyyy HH:mm:ss zzz",
        "EEE MMM d HH:mm:ss yyyy",
    ]

    /// Its attributes in a few words, such as "Path / · Secure · HttpOnly".
    public var attributes: [String] {
        var words: [String] = []
        if let domain { words.append("Domain \(domain)") }
        if let path { words.append("Path \(path)") }
        if let maxAge { words.append("Max-Age \(maxAge)") }
        if isSecure { words.append("Secure") }
        if isHTTPOnly { words.append("HttpOnly") }
        if let sameSite { words.append("SameSite \(sameSite)") }
        if isPartitioned { words.append("Partitioned") }
        return words
    }
}

extension Headers {
    /// The cookies in the `Cookie` headers, such as `a=1; b=2`, in order.
    public var requestCookies: [RequestCookie] {
        values(named: "Cookie").flatMap { header in
            header.split(separator: ";").compactMap { pair -> RequestCookie? in
                let pair = pair.trimmingCharacters(in: .whitespaces)
                guard !pair.isEmpty else { return nil }
                guard let equals = pair.firstIndex(of: "=") else { return RequestCookie(name: "", value: pair) }
                return RequestCookie(
                    name: String(pair[..<equals]), value: String(pair[pair.index(after: equals)...]))
            }
        }
    }

    /// The cookies in the `Set-Cookie` headers, one per header.
    public var responseCookies: [ResponseCookie] {
        values(named: "Set-Cookie").compactMap(ResponseCookie.init(setCookie:))
    }
}
