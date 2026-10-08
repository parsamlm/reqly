import Foundation
import ReqlyModel

public enum HARError: Error, Equatable {
    /// The file isn't a HAR file, or Reqly can't read it.
    case unreadable(String)
}

/// Reads the exchanges in a HAR file, with their bodies, from browsers and other tools.
public enum HARReader {
    /// An exchange from the file, with its messages if it switched to WebSocket.
    public struct Entry: Sendable {
        public var exchange: Exchange
        public var messages: [WebSocketMessage]
    }

    /// The file's exchanges, oldest first, numbered from 1.
    public static func exchanges(from data: Data) throws -> [Exchange] {
        try entries(from: data).map(\.exchange)
    }

    /// The file's exchanges and their WebSocket messages, oldest first, numbered from 1.
    public static func entries(from data: Data) throws -> [Entry] {
        let file: HARFile
        do {
            file = try JSONDecoder().decode(HARFile.self, from: data)
        } catch {
            throw HARError.unreadable("Reqly couldn't read this file as HAR.")
        }
        return file.log.entries.enumerated().compactMap { index, entry in
            guard var exchange = exchange(from: entry, id: UInt64(index + 1)) else { return nil }
            let messages = (entry.webSocketMessages ?? []).compactMap(message)
            exchange.messageCount = messages.count
            return Entry(exchange: exchange, messages: messages)
        }
        .sorted { $0.exchange.timing.started < $1.exchange.timing.started }
    }

    static func message(_ message: HARFile.WebSocketMessage) -> WebSocketMessage? {
        let kind: WebSocketMessage.Kind
        switch message.opcode {
        case 1: kind = .text
        case 2: kind = .binary
        case 8: kind = .close
        case 9: kind = .ping
        case 10: kind = .pong
        default: return nil
        }
        let data =
            kind == .text || kind == .close
            ? Data(message.data.utf8) : Data(base64Encoded: message.data) ?? Data(message.data.utf8)
        return WebSocketMessage(
            direction: message.type == "send" ? .sent : .received, kind: kind,
            time: Date(timeIntervalSince1970: message.time), data: data, closeCode: message.closeCode)
    }

    static func exchange(from entry: HARFile.Entry, id: UInt64) -> Exchange? {
        guard let components = URLComponents(string: entry.request.url), let host = components.host,
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery {
            target += "?" + query
        }
        let request = RequestHead(
            method: entry.request.method,
            scheme: scheme,
            host: host.lowercased(),
            port: components.port ?? (scheme == "https" ? 443 : 80),
            target: target,
            version: version(entry.request.httpVersion),
            headers: headers(entry.request.headers)
        )
        let started = date(entry.startedDateTime) ?? Date(timeIntervalSinceReferenceDate: 0)
        var exchange = Exchange(
            id: ExchangeID(rawValue: id),
            connectionID: ConnectionID(rawValue: entry.connection.flatMap(UInt64.init) ?? id),
            kind: .http,
            request: request,
            started: started
        )
        exchange.requestBody = body(entry.request.postData?.text, encoding: entry.request.postData?.encoding)
        exchange.bytesSent = Int64(exchange.requestBody.count)

        let response = entry.response
        if response.status > 0 {
            var headers = headers(response.headers)
            // HAR keeps bodies unpacked, so they no longer match a Content-Encoding.
            headers.remove(named: "Content-Encoding")
            exchange.response = ResponseHead(
                status: response.status, reason: response.statusText ?? "",
                version: version(response.httpVersion), headers: headers)
            exchange.responseBody = body(response.content?.text, encoding: response.content?.encoding)
            exchange.bytesReceived = Int64(exchange.responseBody.count)
            exchange.state = .completed
        } else {
            exchange.state = .failed(.recorded(entry.error ?? "The file has no response for this request."))
        }
        exchange.timing = timing(entry.timings, started: started, total: entry.time)
        exchange.reusedConnection = (entry.timings?.connect ?? -1) < 0 && exchange.timing.connectStarted == nil
        exchange.remoteAddress = entry.serverIPAddress.flatMap { $0.isEmpty ? nil : $0 }
        exchange.clientCertificate = entry.clientCertificate.flatMap { $0.isEmpty ? nil : $0 }
        exchange.reverseProxy = entry.reverseProxy.flatMap { $0.isEmpty ? nil : $0 }
        exchange.sentByReqly = entry.sentByReqly ?? false
        if let comment = entry.comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty {
            exchange.annotation.comment = comment
        }
        return exchange
    }

    /// Each step starts where the one before ended, as Reqly records them.
    static func timing(_ timings: HARFile.Timings?, started: Date, total: Double?) -> ExchangeTiming {
        var timing = ExchangeTiming(started: started)
        var mark = started
        func step(_ milliseconds: Double?) -> Date? {
            guard let milliseconds, milliseconds >= 0 else { return nil }
            mark += milliseconds / 1000
            return mark
        }
        guard let timings else {
            timing.ended = total.map { started + $0 / 1000 }
            return timing
        }
        let handshake = max(timings.ssl ?? -1, -1)
        let connecting = timings.connect.map { $0 >= 0 ? $0 - max(handshake, 0) : -1 }
        if (timings.connect ?? -1) >= 0 {
            timing.connectStarted = step(timings.blocked) ?? started
            timing.resolved = step(timings.dns)
            timing.connected = step(connecting)
            timing.secured = handshake >= 0 ? step(handshake) : nil
        } else {
            _ = step(timings.blocked)
            _ = step(timings.dns)
        }
        timing.requestSent = step(timings.send)
        timing.requestEnded = timing.requestSent
        timing.responseStarted = step(timings.wait)
        timing.ended = step(timings.receive) ?? total.map { started + $0 / 1000 }
        return timing
    }

    /// Headers without HTTP/2's pseudo-headers, such as `:method`, which some tools write too.
    private static func headers(_ fields: [HARFile.NameValue]?) -> Headers {
        Headers((fields ?? []).filter { !$0.name.hasPrefix(":") }.map { HeaderField(name: $0.name, value: $0.value) })
    }

    private static func body(_ text: String?, encoding: String?) -> Data {
        guard let text else { return Data() }
        if encoding?.lowercased() == "base64" {
            return Data(base64Encoded: text) ?? Data()
        }
        return Data(text.utf8)
    }

    /// `HTTP/1.1` as it is; `h2` and `HTTP/2.0` as `HTTP/2`.
    private static func version(_ text: String?) -> String {
        switch text?.lowercased() {
        case "h2", "http/2", "http/2.0": "HTTP/2"
        case "h3", "http/3", "http/3.0": "HTTP/3"
        case "http/1.0": "HTTP/1.0"
        case .some(let other) where other.hasPrefix("http/"): text!
        default: "HTTP/1.1"
        }
    }

    private static func date(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}
