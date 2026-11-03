import BodyKit
import CoreInterface
import Foundation
import Presentation
import ReqlyModel

/// What the Request and Response pages say of one message, as the Mac's do: the query's
/// parameters, on the Request page; the headers; the cookies it sent, or the ones it set; the body,
/// or a line saying there's none; and the response's trailers. An encrypted connection's response
/// can't be read, and a response that hasn't come says so.
struct MessageWords: Hashable {
    /// A header, and whether it's a secret, such as a cookie or a token, which shows as dots until
    /// you show it.
    struct Header: Hashable {
        var name: String
        var value: String
        var isSecret: Bool
    }

    /// A cookie, with when it expires and its other attributes, such as "Path /" and "Secure".
    struct Cookie: Hashable {
        var name: String
        var value: String
        var attributes: String?
    }

    var query: [DetailsRow] = []
    var headers: [Header] = []
    var cookies: [Cookie] = []
    var trailers: [Header] = []
    /// Whether the message has a body to show.
    var hasBody = false
    /// The body's size, so a body that grows is shown again.
    var bodySize = 0
    /// What the page says in place of the body, such as "This request has no body.", or in place of
    /// the whole page, such as "No response yet."
    var note: String?
    /// Whether ``note`` stands for the whole page, as for a response that hasn't come.
    var isWholePage = false

    init(_ details: ExchangeDetails, part: MessagePart, locale: Locale = .current, timeZone: TimeZone = .current) {
        let exchange = details.exchange
        switch part {
        case .request:
            query = details.query.map { DetailsRow(name: $0.name, value: $0.value, isCode: true) }
            headers = Self.headers(exchange.request.headers)
            cookies = details.requestCookies.map { Cookie(name: $0.name, value: $0.value) }
            bodySize = exchange.requestBody.count
            hasBody = bodySize > 0
            note = hasBody ? nil : "This request has no body."
        case .response:
            guard let response = exchange.response else {
                note =
                    exchange.kind == .tunnel
                    ? "Reqly doesn't decrypt this host, so the response isn't readable." : "No response yet."
                isWholePage = true
                return
            }
            headers = Self.headers(response.headers)
            cookies = details.responseCookies.map {
                Cookie(
                    name: $0.name, value: $0.value,
                    attributes: Self.attributes(of: $0, locale: locale, timeZone: timeZone))
            }
            bodySize = exchange.responseBody.count
            hasBody = bodySize > 0
            note = hasBody ? nil : "This response has no body."
            trailers = exchange.responseTrailers.map(Self.headers) ?? []
        }
    }

    private static func headers(_ headers: Headers) -> [Header] {
        headers.map { Header(name: $0.name, value: $0.value, isSecret: $0.isSecret) }
    }

    /// When a cookie expires, then the rest of its attributes, such as
    /// "Expires Oct 21, 2026 at 07:28 · Path / · Secure", or `nil` when it has none.
    static func attributes(
        of cookie: ExchangeDetails.Cookie, locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String? {
        var words: [String] = []
        if let date = cookie.expires {
            words.append("Expires \(DetailsFormat.day(date, locale: locale, timeZone: timeZone))")
        } else if let expires = cookie.expiresText {
            words.append("Expires \(expires)")
        }
        words += cookie.attributes
        return words.isEmpty ? nil : words.joined(separator: " · ")
    }

    /// What Copy Headers copies: each header on a line of its own, as "Name: value", secrets and
    /// all.
    var headersText: String {
        headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }

    /// A secret's value hidden: as many dots as it has characters, but at least 8 and at most 16,
    /// so the dots don't give its length away.
    static func mask(_ value: String) -> String {
        String(repeating: "•", count: min(max(value.count, 8), 16))
    }

    /// A cookie's name, or "No name" for one that has none.
    static func name(of cookie: Cookie) -> String {
        cookie.name.isEmpty ? "No name" : cookie.name
    }
}

/// What the Raw page says around the request and response as text, in the Mac's words.
enum RawWords {
    /// The line about secrets, while the exchange has any, and its button's title.
    static func secrets(showing: Bool) -> (text: String, button: String) {
        showing
            ? ("Cookies and authorization headers are showing.", "Hide Them")
            : ("Cookies and authorization headers are hidden.", "Show Them")
    }

    /// What shows in place of the response, until there's one.
    static func noResponse(_ exchange: Exchange) -> String {
        exchange.kind == .tunnel ? "Reqly doesn't decrypt this host." : "No response yet."
    }

    /// The note under the text for HTTP/2, which isn't text on the wire, or `nil`.
    static func note(_ exchange: Exchange) -> String? {
        exchange.request.version == "HTTP/2"
            ? "HTTP/2 sends these as binary frames. Reqly writes them the way HTTP/1.1 does, so they're easy to read."
            : nil
    }

    /// Whether any of the exchange's headers is a secret, so the page offers to show them.
    static func hasSecrets(_ exchange: Exchange) -> Bool {
        exchange.request.headers.contains(where: \.isSecret)
            || exchange.response?.headers.contains(where: \.isSecret) == true
    }
}

/// A message as the Raw page shows it, from the core's `RawMessage`: its text, and where its
/// header names and its notes about bodies are, in characters, as a GTK text buffer counts them.
struct RawText: Hashable {
    var text: String
    var names: [Range<Int>]
    var notes: [Range<Int>]

    init(_ message: RawMessage) {
        self.init(text: message.text, tokens: message.tokens)
    }

    /// `tokens` count UTF-16 code units, as the core's do; a buffer counts Unicode scalars. A NUL,
    /// which a buffer can't hold, shows as U+FFFD.
    init(text: String, tokens: [SyntaxToken]) {
        self.text = text.contains("\u{0}") ? text.replacingOccurrences(of: "\u{0}", with: "\u{FFFD}") : text
        let places = Set(tokens.flatMap { [$0.location, $0.location + $0.length] }).sorted()
        var characters: [Int: Int] = [:]
        var next = 0
        var units = 0
        var scalars = 0
        for scalar in text.unicodeScalars {
            while next < places.count, places[next] <= units {
                characters[places[next]] = scalars
                next += 1
            }
            units += scalar.utf16.count
            scalars += 1
        }
        while next < places.count {
            characters[places[next]] = scalars
            next += 1
        }
        func range(_ token: SyntaxToken) -> Range<Int>? {
            guard let start = characters[token.location], let end = characters[token.location + token.length],
                start < end
            else { return nil }
            return start..<end
        }
        names = tokens.filter { $0.kind == .key }.compactMap(range)
        notes = tokens.filter { $0.kind == .comment }.compactMap(range)
    }
}
