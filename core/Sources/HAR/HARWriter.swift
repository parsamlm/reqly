import BodyKit
import Foundation
import ReqlyModel

/// Writes exchanges to a HAR 1.2 file, one entry at a time, so a big export never holds them
/// all in memory. Call ``finish()`` once the last one is in.
public final class HARWriter {
    public struct Options: Sendable, Hashable {
        public var includesResponseBodies: Bool
        /// Replaces authorization headers and cookies with a placeholder.
        public var hidesSecrets: Bool

        public init(includesResponseBodies: Bool = true, hidesSecrets: Bool = true) {
            self.includesResponseBodies = includesResponseBodies
            self.hidesSecrets = hidesSecrets
        }
    }

    private let handle: FileHandle
    private let options: Options
    private let encoder = JSONEncoder()
    private var count = 0

    /// Starts the file at `url`, replacing any file there.
    public init(url: URL, options: Options, creatorVersion: String) throws {
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        handle = try FileHandle(forWritingTo: url)
        self.options = options
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let creator = try encoder.encode(HARFile.Creator(name: "Reqly", version: creatorVersion))
        try write("{\"log\":{\"version\":\"1.2\",\"creator\":")
        try handle.write(contentsOf: creator)
        try write(",\"entries\":[")
    }

    deinit {
        try? handle.close()
    }

    /// Adds an exchange, with its messages if it switched to WebSocket. Encrypted connections
    /// have no request to show, so they're skipped.
    public func append(_ exchange: Exchange, messages: [WebSocketMessage] = []) throws {
        guard exchange.kind == .http else { return }
        var entry = Self.entry(for: options.hidesSecrets ? exchange.hidingSecrets() : exchange, options: options)
        if !messages.isEmpty {
            entry.resourceType = "websocket"
            entry.webSocketMessages = messages.map(Self.message)
        }
        try write(count == 0 ? "\n" : ",\n")
        try handle.write(contentsOf: try encoder.encode(entry))
        count += 1
    }

    public func finish() throws {
        try write("\n]}}\n")
        try handle.close()
    }

    private func write(_ text: String) throws {
        try handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: - Entries

    static func message(_ message: WebSocketMessage) -> HARFile.WebSocketMessage {
        let opcode =
            switch message.kind {
            case .text: 1
            case .binary: 2
            case .close: 8
            case .ping: 9
            case .pong: 10
            }
        let data =
            message.kind == .text || message.kind == .close
            ? message.text ?? message.data.base64EncodedString() : message.data.base64EncodedString()
        return HARFile.WebSocketMessage(
            type: message.direction == .sent ? "send" : "receive", time: message.time.timeIntervalSince1970,
            opcode: opcode, data: data, closeCode: message.closeCode)
    }

    static func entry(for exchange: Exchange, options: Options) -> HARFile.Entry {
        let timings = Self.timings(for: exchange)
        let total = [timings.blocked, timings.dns, timings.connect, timings.send, timings.wait, timings.receive]
            .compactMap { $0 }.filter { $0 >= 0 }.reduce(0, +)
        var serverIP = exchange.remoteAddress
        if let address = serverIP, let colon = address.lastIndex(of: ":") {
            // The address without its port, and without the brackets around an IPv6 address.
            serverIP = String(address[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        }
        var error: String?
        if case .failed(let failure) = exchange.state {
            error = failure.message
        }
        return HARFile.Entry(
            startedDateTime: Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(exchange.timing.started),
            time: total,
            request: request(for: exchange),
            response: response(for: exchange, options: options),
            cache: HARFile.Cache(),
            timings: timings,
            serverIPAddress: serverIP,
            connection: String(exchange.connectionID.rawValue),
            comment: exchange.annotation.comment,
            error: error,
            clientCertificate: exchange.clientCertificate,
            reverseProxy: exchange.reverseProxy,
            sentByReqly: exchange.sentByReqly ? true : nil
        )
    }

    private static func request(for exchange: Exchange) -> HARFile.Request {
        let request = exchange.request
        var postData: HARFile.PostData?
        if !exchange.requestBody.isEmpty {
            let contentType = request.headers["Content-Type"]
            if let text = BodyText.decode(exchange.requestBody, contentType: contentType) {
                postData = HARFile.PostData(mimeType: contentType ?? "", text: text)
            } else {
                postData = HARFile.PostData(
                    mimeType: contentType ?? "", text: exchange.requestBody.base64EncodedString(), encoding: "base64")
            }
        }
        return HARFile.Request(
            method: request.method,
            url: request.url?.absoluteString ?? "",
            httpVersion: request.version,
            cookies: request.headers.values(named: "Cookie").filter { $0 != Headers.hiddenValue }
                .flatMap(requestCookies),
            headers: request.headers.map { HARFile.NameValue(name: $0.name, value: $0.value) },
            queryString: queryParameters(request.query),
            postData: postData,
            headersSize: -1,
            bodySize: exchange.requestBody.count
        )
    }

    private static func response(for exchange: Exchange, options: Options) -> HARFile.Response {
        guard let response = exchange.response else {
            return HARFile.Response(
                status: 0, statusText: "", httpVersion: "", cookies: [], headers: [],
                content: HARFile.Content(size: 0, mimeType: "x-unknown"), redirectURL: "", headersSize: -1,
                bodySize: -1)
        }
        let wire = exchange.responseBody
        let encoding = response.headers["Content-Encoding"].flatMap { $0.lowercased() == "identity" ? nil : $0 }
        let body = encoding.flatMap { BodyDecoder.decode(wire, contentEncoding: $0) } ?? wire
        let contentType = response.headers["Content-Type"]
        var content = HARFile.Content(
            size: body.count, compression: body.count > wire.count ? body.count - wire.count : nil,
            mimeType: contentType ?? "x-unknown")
        if options.includesResponseBodies, !body.isEmpty {
            if let text = BodyText.decode(body, contentType: contentType) {
                content.text = text
            } else {
                content.text = body.base64EncodedString()
                content.encoding = "base64"
            }
        }
        return HARFile.Response(
            status: response.status,
            statusText: response.reason,
            httpVersion: response.version,
            cookies: response.headers.values(named: "Set-Cookie").filter { $0 != Headers.hiddenValue }
                .compactMap(responseCookie),
            headers: response.headers.map { HARFile.NameValue(name: $0.name, value: $0.value) },
            content: content,
            redirectURL: response.headers["Location"] ?? "",
            headersSize: -1,
            bodySize: Int(exchange.bytesReceived)
        )
    }

    /// The steps of the exchange in milliseconds, with -1 for a step that didn't happen, as the
    /// format asks. `connect` includes the TLS handshake.
    static func timings(for exchange: Exchange) -> HARFile.Timings {
        var milliseconds: [TimingPhase.Step: Double] = [:]
        for phase in exchange.timingPhases {
            milliseconds[phase.step, default: 0] += phase.duration * 1000
        }
        let connecting = milliseconds[.connecting]
        let handshake = milliseconds[.tlsHandshake]
        return HARFile.Timings(
            blocked: milliseconds[.queued] ?? -1,
            dns: milliseconds[.dnsLookup] ?? -1,
            connect: connecting.map { $0 + (handshake ?? 0) } ?? -1,
            send: milliseconds[.requestSent] ?? 0,
            wait: milliseconds[.waiting] ?? 0,
            receive: (milliseconds[.downloading] ?? 0) + (milliseconds[.open] ?? 0),
            ssl: handshake ?? -1
        )
    }

    /// `a=1; b=2` from a Cookie header.
    static func requestCookies(_ header: String) -> [HARFile.Cookie] {
        header.split(separator: ";").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let name = parts.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            return HARFile.Cookie(name: name, value: parts.count > 1 ? String(parts[1]) : "")
        }
    }

    /// `name=value; Path=/; HttpOnly` from a Set-Cookie header.
    static func responseCookie(_ header: String) -> HARFile.Cookie? {
        var attributes = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !attributes.isEmpty else { return nil }
        let pair = attributes.removeFirst().split(separator: "=", maxSplits: 1)
        guard let name = pair.first, !name.isEmpty else { return nil }
        var cookie = HARFile.Cookie(name: String(name), value: pair.count > 1 ? String(pair[1]) : "")
        for attribute in attributes {
            let parts = attribute.split(separator: "=", maxSplits: 1)
            switch parts.first?.lowercased() {
            case "path": cookie.path = parts.count > 1 ? String(parts[1]) : nil
            case "domain": cookie.domain = parts.count > 1 ? String(parts[1]) : nil
            case "httponly": cookie.httpOnly = true
            case "secure": cookie.secure = true
            default: break
            }
        }
        return cookie
    }

    static func queryParameters(_ query: String?) -> [HARFile.NameValue] {
        guard let query, !query.isEmpty else { return [] }
        return query.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).removingPercentEncoding ?? String($0)
            }
            return HARFile.NameValue(name: parts.first ?? "", value: parts.count > 1 ? parts[1] : "")
        }
    }
}
