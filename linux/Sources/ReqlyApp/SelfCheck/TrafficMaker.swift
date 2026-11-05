import Foundation
import Synchronization

// Traffic for the self-check's parts, made on this computer, since its container has no network:
// a server on 127.0.0.1 that answers each path with a body of a kind the details show, and a
// client that sends requests through Reqly's proxy, as an app would, one at a time or thousands
// at once.

/// A web server on 127.0.0.1, on a port the kernel picks, that answers each of its ``Path``s as
/// an app's server would. Each connection gets a thread of its own and stays open for the requests
/// that follow on it, as Reqly's proxy keeps its connections to servers. It answers until it stops.
final class TestServer: Sendable {
    /// What the server answers. Each takes `?status=404` for another status, and `?ms=500` to
    /// wait that long before answering.
    enum Path: String, CaseIterable, Sendable {
        /// A forecast in JSON, with an object, an array, numbers, true and null.
        case json = "/json"
        case xml = "/xml"
        case html = "/html"
        case text = "/text"
        /// A form, `application/x-www-form-urlencoded`.
        case form = "/form"
        /// `multipart/form-data`: a text field and a PNG file.
        case multipart = "/multipart"
        /// A 16 × 12 PNG, teal fading to clear.
        case image = "/image.png"
        /// JSON packed with gzip, as `Content-Encoding: gzip` says.
        case gzip = "/gzip"
        /// Two Set-Cookie headers, one with an expiry and attributes.
        case cookies = "/cookies"
        /// JSON for a request with an Authorization header, and 401 without one.
        case me = "/me"
        /// Plain text after a second, or `ms=`.
        case slow = "/slow"
        /// No answer: the server closes the connection, so the request fails.
        case fail = "/fail"
        /// Lines of text, a megabyte of them, or `bytes=`.
        case big = "/big"
        /// Lines of text sent a piece at a time, as a download comes: `pieces=` pieces of a
        /// kilobyte, 8 unless it says, `gap=` milliseconds apart, 250 unless it says.
        case drip = "/drip"
        /// "ok", as any other path answers.
        case ok = "/ok"
    }

    let port: Int
    private let listener: Int32
    /// The connections open now, so stopping closes them.
    private let open = Mutex<Set<Int32>>([])

    init() throws {
        (listener, port) = try Loopback.listen()
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                open.withLock { _ = $0.insert(client) }
                Thread.detachNewThread { [self] in
                    serve(HTTPWire(client))
                    // Closed while no stop can shut it down, so its number can't be another's then.
                    open.withLock {
                        $0.remove(client)
                        close(client)
                    }
                }
            }
        }
    }

    /// Where it is, such as `127.0.0.1:41234`, for a request's Host.
    var origin: String { "127.0.0.1:\(port)" }

    /// A path's full URL, with a query if there is one, such as `status=500`.
    func url(_ path: Path, _ query: String? = nil) -> String {
        "http://\(origin)\(path.rawValue)" + (query.map { "?\($0)" } ?? "")
    }

    /// Stops accepting, and closes every connection, which ends the server's threads.
    func stop() {
        shutdown(listener, Int32(SHUT_RDWR))
        close(listener)
        open.withLock { clients in
            for client in clients {
                shutdown(client, Int32(SHUT_RDWR))
            }
        }
    }

    /// Answers the requests on a connection until it closes, or one says to close it.
    private func serve(_ wire: HTTPWire) {
        while let (start, headers) = wire.head() {
            let parts = start.split(separator: " ")
            guard parts.count == 3, let body = wire.body(of: headers) else { return }
            let target = String(parts[1])
            guard let answer = Self.answer(target, headers: headers, body: body) else { return }
            if answer.wait > 0 {
                usleep(useconds_t(answer.wait) * 1000)
            }
            // The head and the first piece, then each piece after a gap.
            let bytes = answer.bytes
            let piece = max(1, answer.body.count / max(1, answer.pieces))
            var sent = bytes.count - answer.body.count + piece
            guard wire.write(Array(bytes[..<min(sent, bytes.count)])) else { return }
            while sent < bytes.count {
                usleep(useconds_t(answer.gap) * 1000)
                let end = min(sent + piece, bytes.count)
                guard wire.write(Array(bytes[sent..<end])) else { return }
                sent = end
            }
            if HTTPWire.value("Connection", in: headers)?.lowercased() == "close" { return }
        }
    }

    /// What answers a request, or `nil` for one the server gives no answer.
    private struct Answer {
        var status = 200
        var headers: [(name: String, value: String)] = []
        var body: [UInt8] = []
        /// How long to wait first, in milliseconds.
        var wait = 0
        /// How many pieces the body goes in, each `gap` milliseconds after the one before.
        var pieces = 1
        var gap = 0

        var bytes: [UInt8] {
            var head = "HTTP/1.1 \(status) \(HTTPWire.reason(status))\r\n"
            for header in headers {
                head += "\(header.name): \(header.value)\r\n"
            }
            head += "Content-Length: \(body.count)\r\n\r\n"
            return Array(head.utf8) + body
        }
    }

    private static func answer(
        _ target: String, headers: [(name: String, value: String)], body: [UInt8]
    ) -> Answer? {
        let (path, query) = split(target)
        var answer = Answer()
        func content(_ type: String, _ text: String) {
            answer.headers.append(("Content-Type", type))
            answer.body = Array(text.utf8)
        }
        switch Path(rawValue: path) ?? .ok {
        case .json:
            content(
                "application/json",
                #"{"city":"Tehran","days":[{"sky":"clear","high":31},{"sky":"rain","high":24}],"updated":true,"note":null}"#
            )
        case .xml:
            content(
                "application/xml",
                #"<?xml version="1.0" encoding="UTF-8"?><forecast city="Tehran"><day sky="clear" high="31"/>"#
                    + #"<day sky="rain" high="24"/></forecast>"#)
        case .html:
            content(
                "text/html; charset=utf-8",
                "<!doctype html><html><head><title>Weather</title></head><body><h1>Tehran</h1><p>Clear, 31°</p>"
                    + "</body></html>")
        case .text:
            content("text/plain; charset=utf-8", "Clear skies over Tehran.\nRain tomorrow.\n")
        case .form:
            content("application/x-www-form-urlencoded", "city=Tehran&days=3&units=metric")
        case .multipart:
            let boundary = "reqly-self-check"
            answer.headers.append(("Content-Type", "multipart/form-data; boundary=\(boundary)"))
            answer.body =
                Array(
                    "--\(boundary)\r\nContent-Disposition: form-data; name=\"city\"\r\n\r\nTehran\r\n--\(boundary)\r\n"
                        .utf8)
                + Array(
                    "Content-Disposition: form-data; name=\"map\"; filename=\"map.png\"\r\nContent-Type: image/png\r\n\r\n"
                        .utf8)
                + png + Array("\r\n--\(boundary)--\r\n".utf8)
        case .image:
            answer.headers.append(("Content-Type", "image/png"))
            answer.body = png
        case .gzip:
            answer.headers += [("Content-Type", "application/json"), ("Content-Encoding", "gzip")]
            answer.body = packedJSON
        case .cookies:
            answer.headers += [
                ("Set-Cookie", "session=7f3a9c; Path=/; Secure; HttpOnly"),
                ("Set-Cookie", "theme=dark; Expires=Wed, 21 Oct 2026 07:28:00 GMT; SameSite=Lax"),
            ]
            content("application/json", #"{"signedIn":true}"#)
        case .me:
            if HTTPWire.value("Authorization", in: headers) == nil {
                answer.status = 401
                answer.headers.append(("WWW-Authenticate", "Bearer"))
                content("application/json", #"{"error":"Sign in first."}"#)
            } else {
                content("application/json", #"{"name":"Parsa","plan":"free"}"#)
            }
        case .slow:
            answer.wait = 1000
            content("text/plain", "At last.")
        case .fail:
            return nil
        case .big:
            let size = query["bytes"].flatMap { Int($0) } ?? 1 << 20
            let line = Array("The quick brown fox jumps over the lazy dog, again and again.\n".utf8)
            answer.headers.append(("Content-Type", "text/plain"))
            answer.body = (0..<size).map { line[$0 % line.count] }
        case .drip:
            let line = Array("The quick brown fox jumps over the lazy dog, again and again.\n".utf8)
            answer.pieces = query["pieces"].flatMap { Int($0) } ?? 8
            answer.gap = query["gap"].flatMap { Int($0) } ?? 250
            answer.headers.append(("Content-Type", "text/plain"))
            answer.body = (0..<answer.pieces * 1000).map { line[$0 % line.count] }
        case .ok:
            content("text/plain", "ok")
        }
        if let status = query["status"].flatMap({ Int($0) }) {
            answer.status = status
        }
        if let wait = query["ms"].flatMap({ Int($0) }) {
            answer.wait = wait
        }
        return answer
    }

    /// A target's path, and its query's names and values. A full URL, as a proxy gets, counts
    /// from its path.
    private static func split(_ target: String) -> (path: String, query: [String: String]) {
        var target = Substring(target)
        if let scheme = target.range(of: "://") {
            let rest = target[scheme.upperBound...]
            target = rest.firstIndex(of: "/").map { rest[$0...] } ?? "/"
        }
        let pieces = target.split(separator: "?", maxSplits: 1)
        var query: [String: String] = [:]
        for pair in pieces.dropFirst().first?.split(separator: "&") ?? [] {
            let halves = pair.split(separator: "=", maxSplits: 1)
            query[String(halves[0])] = halves.count > 1 ? String(halves[1]) : ""
        }
        return (pieces.first.map(String.init) ?? "/", query)
    }

    /// The picture ``Path/image`` answers with.
    static let png = [UInt8](
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAABAAAAAMCAYAAABr5z2BAAAAPElEQVR42mPgntX8H4jfA/F9ID4PxPuBeD0QzwfifiCuB+J8II4HYn8gtgdifSCWB2J+hlEDRg0YHgYAAAy8Q1BhkEmiAAAAAElFTkSuQmCC"
        )!)

    /// ``Path/gzip``'s body: `{"city":"Tehran","packed":true,…}`, packed.
    static let packedJSON = [UInt8](
        Data(
            base64Encoded:
                "H4sIAAAAAAAC/6tWSs4sqVSyUgpJzShKzFPSUSpITM5OTVGyKikqTdVRSkmsLFayiq5WKs4GqUrOSU0sAirKyEzPULIyNqzVgckUJWbmwSWMTGpjawGs06nOWwAAAA=="
        )!)
}

/// An app's requests, sent through Reqly's proxy on 127.0.0.1 as an app sends them through a
/// proxy: plain HTTP/1.1, with each request's full URL.
struct ProxyClient: Sendable {
    /// What came back.
    struct Response: Sendable {
        var status: Int
        var headers: [(name: String, value: String)]
        var body: [UInt8]

        var text: String { String(decoding: body, as: UTF8.self) }
    }

    /// How a burst went.
    struct Burst: Sendable, CustomStringConvertible {
        var sent = 0
        /// How many requests got an answer, by status.
        var statuses: [Int: Int] = [:]
        /// What went wrong with the ones that got none, at most a few.
        var problems: [String] = []
        var seconds = 0.0

        var answered: Int { statuses.values.reduce(0, +) }

        var description: String {
            let counts = statuses.keys.sorted().map { "\(statuses[$0] ?? 0) × \($0)" }.joined(separator: ", ")
            return String(format: "%d sent, %d answered (%@) in %.2f s", sent, answered, counts, seconds)
        }
    }

    let proxyPort: Int

    /// Sends one request on a connection of its own, and gives the answer. A request Reqly
    /// couldn't send on has its answer from Reqly, such as 502 for a server that closed.
    func send(
        _ url: String, method: String = "GET", headers: [(name: String, value: String)] = [], body: [UInt8] = []
    ) async throws -> Response {
        try await onOwnThread { () -> Result<Response, any Error> in
            Result {
                let wire = HTTPWire(try Loopback.connect(to: proxyPort))
                defer { close(wire.socket) }
                let closing = headers + [("Connection", "close")]
                let request = Self.request(url, method: method, headers: closing, body: body)
                guard wire.write(request), let response = wire.response() else {
                    throw Loopback.Failed(step: "the request for \(url)")
                }
                return response
            }
        }.get()
    }

    /// Sends a request for each URL, in order, across `connections` connections at once, each
    /// kept open for its next request, as fast as Reqly answers, and gives how it went.
    func burst(_ urls: [String], connections: Int = 8) async -> Burst {
        let started = Date()
        let shares = (0..<max(1, connections)).map { worker in
            stride(from: worker, to: urls.count, by: max(1, connections)).map { urls[$0] }
        }
        var burst = Burst()
        await withTaskGroup(of: Burst.self) { group in
            for share in shares where !share.isEmpty {
                group.addTask { await onOwnThread { sendShare(share) } }
            }
            for await part in group {
                burst.sent += part.sent
                burst.statuses.merge(part.statuses, uniquingKeysWith: +)
                burst.problems += part.problems.prefix(max(0, 3 - burst.problems.count))
            }
        }
        burst.seconds = Date().timeIntervalSince(started)
        return burst
    }

    /// One connection's share of a burst, a request at a time, connecting again when the proxy
    /// closes it.
    private func sendShare(_ urls: [String]) -> Burst {
        var burst = Burst()
        var wire: HTTPWire?
        for url in urls {
            burst.sent += 1
            do {
                let connection = try wire ?? HTTPWire(Loopback.connect(to: proxyPort))
                wire = connection
                guard connection.write(Self.request(url, method: "GET", headers: [], body: [])),
                    let response = connection.response()
                else {
                    throw Loopback.Failed(step: "the request for \(url)")
                }
                burst.statuses[response.status, default: 0] += 1
                if connection.isClosed || HTTPWire.value("Connection", in: response.headers)?.lowercased() == "close" {
                    close(connection.socket)
                    wire = nil
                }
            } catch {
                if burst.problems.count < 3 { burst.problems.append("\(error)") }
                if let connection = wire { close(connection.socket) }
                wire = nil
            }
        }
        if let wire { close(wire.socket) }
        return burst
    }

    private static func request(
        _ url: String, method: String, headers: [(name: String, value: String)], body: [UInt8]
    ) -> [UInt8] {
        // The authority, between the scheme and the path.
        let authority = url.split(separator: "/", omittingEmptySubsequences: true).dropFirst().first ?? ""
        var head = "\(method) \(url) HTTP/1.1\r\nHost: \(authority)\r\n"
        for header in headers {
            head += "\(header.name): \(header.value)\r\n"
        }
        if !body.isEmpty || ["POST", "PUT", "PATCH"].contains(method) {
            head += "Content-Length: \(body.count)\r\n"
        }
        return Array((head + "\r\n").utf8) + body
    }
}

/// One end of an HTTP/1.1 connection, read a message at a time: its head, then its body, as its
/// headers frame it. Used from one thread at a time.
final class HTTPWire {
    let socket: Int32
    private var buffer: [UInt8] = []
    /// What each read takes in, before the buffer has it: one for the connection, rather than a
    /// new one for every read, which malloc would keep in this thread's arena once it's freed.
    private var chunk = [UInt8](repeating: 0, count: 64 << 10)
    /// Whether the other end has closed.
    private(set) var isClosed = false

    init(_ socket: Int32) {
        self.socket = socket
    }

    /// The next message's start line, such as `GET /json HTTP/1.1`, and its headers, or `nil`
    /// once the other end closes.
    func head() -> (start: String, headers: [(name: String, value: String)])? {
        let end: Int
        while true {
            if let found = Self.find([0x0D, 0x0A, 0x0D, 0x0A], in: buffer) {
                end = found
                break
            }
            guard fill() else { return nil }
        }
        let lines = String(decoding: buffer[..<end], as: UTF8.self).components(separatedBy: "\r\n")
        buffer.removeFirst(end + 4)
        let headers = lines.dropFirst().compactMap { line -> (name: String, value: String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return (lines[0], headers)
    }

    /// The body after a head, as `Content-Length` or chunks frame it, and for a response with
    /// neither, all that comes until the other end closes. `nil` when it ends too soon.
    func body(of headers: [(name: String, value: String)], untilClosed: Bool = false) -> [UInt8]? {
        if Self.value("Transfer-Encoding", in: headers)?.lowercased().contains("chunked") == true {
            var body: [UInt8] = []
            while true {
                guard let line = line(), let size = Int(line.split(separator: ";")[0], radix: 16) else { return nil }
                if size == 0 {
                    // The trailers, up to an empty line.
                    while let trailer = self.line(), !trailer.isEmpty {}
                    return body
                }
                guard let chunk = bytes(size), self.line() != nil else { return nil }
                body += chunk
            }
        }
        if let length = Self.value("Content-Length", in: headers).flatMap({ Int($0) }) {
            return bytes(length)
        }
        guard untilClosed else { return [] }
        while fill() {}
        defer { buffer = [] }
        return buffer
    }

    /// The next response, its status and headers and body, or `nil` when the connection ends
    /// before it does.
    func response() -> ProxyClient.Response? {
        guard let (start, headers) = head() else { return nil }
        let parts = start.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        let hasNoBody = (100..<200).contains(status) || status == 204 || status == 304
        guard let body = hasNoBody ? [] : self.body(of: headers, untilClosed: true) else { return nil }
        return ProxyClient.Response(status: status, headers: headers, body: body)
    }

    /// Writes all of `bytes`, and says whether it could.
    func write(_ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { send(socket, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }

    /// A header's value, by its name in any case.
    static func value(_ name: String, in headers: [(name: String, value: String)]) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// A status's reason, as servers write it.
    static func reason(_ status: Int) -> String {
        let reasons = [
            200: "OK", 201: "Created", 204: "No Content", 301: "Moved Permanently", 302: "Found",
            304: "Not Modified", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
            500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable",
        ]
        return reasons[status] ?? "Status \(status)"
    }

    private func line() -> String? {
        while true {
            if let end = Self.find([0x0D, 0x0A], in: buffer) {
                defer { buffer.removeFirst(end + 2) }
                return String(decoding: buffer[..<end], as: UTF8.self)
            }
            guard fill() else { return nil }
        }
    }

    private func bytes(_ count: Int) -> [UInt8]? {
        while buffer.count < count {
            guard fill() else { return nil }
        }
        defer { buffer.removeFirst(count) }
        return Array(buffer[..<count])
    }

    /// Reads what's arrived into the buffer, and says whether anything did.
    private func fill() -> Bool {
        let count = chunk.withUnsafeMutableBytes { recv(socket, $0.baseAddress, $0.count, 0) }
        guard count > 0 else {
            isClosed = true
            return false
        }
        buffer += chunk[..<count]
        return true
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if haystack[start..<start + needle.count].elementsEqual(needle) {
                return start
            }
        }
        return nil
    }
}
