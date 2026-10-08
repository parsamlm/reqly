import Foundation

/// Which requests a rule applies to: a host, a path and a method. `*` stands for anything.
public struct RequestMatch: Hashable, Sendable, Codable {
    /// Such as `api.weatherly.dev`, `*.weatherly.dev`, or `localhost:9096` for one port.
    public var host: String
    /// Such as `/v2/forecast*`. A pattern with a `?` in it also matches the query.
    public var path: String
    /// `nil` matches every method.
    public var method: String?

    public init(host: String = "*", path: String = "*", method: String? = nil) {
        self.host = host
        self.path = path
        self.method = method
    }

    public func matches(method: String, host: String, port: Int, target: String) -> Bool {
        if let wanted = self.method, wanted != "*", wanted.caseInsensitiveCompare(method) != .orderedSame {
            return false
        }
        let hostPattern = self.host.trimmingCharacters(in: .whitespaces).lowercased()
        let hostText = hostPattern.contains(":") ? "\(host.lowercased()):\(port)" : host.lowercased()
        guard hostPattern.isEmpty || Wildcard.matches(hostPattern, hostText) else { return false }
        var pathPattern = path.trimmingCharacters(in: .whitespaces)
        guard !pathPattern.isEmpty, pathPattern != "*" else { return true }
        if !pathPattern.hasPrefix("/"), !pathPattern.hasPrefix("*") {
            pathPattern = "/" + pathPattern
        }
        let pathText = pathPattern.contains("?") ? target : String(target.prefix { $0 != "?" })
        return Wildcard.matches(pathPattern, pathText)
    }

    /// The request a summary describes.
    public func matches(_ summary: ExchangeSummary) -> Bool {
        matches(method: summary.method, host: summary.host, port: summary.port, target: summary.target)
    }

    /// How the match reads in a list, such as `GET · api.weatherly.dev/v2/forecast*`.
    public var description: String {
        let method = self.method.map { $0 == "*" ? "Any method" : $0 } ?? "Any method"
        let path = path.isEmpty || path == "*" ? "/*" : path
        return "\(method) · \(host.isEmpty ? "*" : host)\(path.hasPrefix("/") ? "" : "/")\(path)"
    }
}

/// `*` matching any run of characters, including none. Everything else matches itself.
enum Wildcard {
    static func matches(_ pattern: String, _ text: String) -> Bool {
        let pattern = Array(pattern.utf8)
        let text = Array(text.utf8)
        var p = 0
        var t = 0
        // Where the last `*` was, and where in the text it started matching.
        var star: Int?
        var starText = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == UInt8(ascii: "*") {
                star = p
                starText = t
                p += 1
            } else if p < pattern.count, pattern[p] == text[t] {
                p += 1
                t += 1
            } else if let star {
                // Let the last `*` take one more character, and try again from there.
                p = star + 1
                starText += 1
                t = starText
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == UInt8(ascii: "*") {
            p += 1
        }
        return p == pattern.count
    }
}

/// A rule that changes traffic: pausing it, answering it, sending it elsewhere, rewriting it or
/// blocking it.
public struct Rule: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var isOn: Bool
    public var match: RequestMatch
    public var action: RuleAction

    public init(id: UUID = UUID(), name: String, isOn: Bool = true, match: RequestMatch, action: RuleAction) {
        self.id = id
        self.name = name
        self.isOn = isOn
        self.match = match
        self.action = action
    }

    public var kind: RuleKind { action.kind }
}

public enum RuleKind: String, Hashable, Sendable, Codable, CaseIterable {
    case breakpoint, mapLocal, mapRemote, rewrite, block, script
    /// Not a rule of its own: ``RuleSet/network`` says which hosts it slows down.
    case slowNetwork
}

public enum RuleAction: Hashable, Sendable, Codable {
    /// Pauses matching traffic, so you can edit it before it goes on.
    case breakpoint(BreakpointPhase)
    /// Answers with a file on your Mac, without asking the server.
    case mapLocal(MapLocal)
    /// Sends the request to another server.
    case mapRemote(MapRemote)
    /// Changes the request or the response as it passes.
    case rewrite([Rewrite])
    case block(Block)
    /// Runs JavaScript on matching traffic.
    case script(Script)

    public var kind: RuleKind {
        switch self {
        case .breakpoint: .breakpoint
        case .mapLocal: .mapLocal
        case .mapRemote: .mapRemote
        case .rewrite: .rewrite
        case .block: .block
        case .script: .script
        }
    }
}

/// JavaScript that runs on matching traffic: `onRequest(request)` before a request goes to
/// the server, and `onResponse(response, request)` before a response goes back to the app.
/// Each run gets the whole message, and what the function changes goes on.
public struct Script: Hashable, Sendable, Codable {
    public var code: String

    public init(code: String) {
        self.code = code
    }

    /// The code has an `onRequest` function, which needs each request whole before it goes on.
    public var runsOnRequest: Bool { mentions("onRequest") }

    /// The code has an `onResponse` function, which needs each response whole before the app
    /// gets it.
    public var runsOnResponse: Bool { mentions("onResponse") }

    private func mentions(_ name: String) -> Bool {
        code.range(of: "\\b\(name)\\b", options: .regularExpression) != nil
    }
}

/// What a script printed with `console.log` while it ran on an exchange.
public struct ScriptOutput: Hashable, Sendable, Codable {
    /// The script's rule, by name.
    public var rule: String
    /// Whether it ran on the request or on the response.
    public var part: MessagePart
    public var lines: [String]

    public init(rule: String, part: MessagePart, lines: [String]) {
        self.rule = rule
        self.part = part
        self.lines = lines
    }
}

public enum BreakpointPhase: String, Hashable, Sendable, Codable, CaseIterable {
    case request, response, both

    public var pausesRequest: Bool { self != .response }
    public var pausesResponse: Bool { self != .request }
}

public struct MapLocal: Hashable, Sendable, Codable {
    /// The file to answer with.
    public var path: String
    public var status: Int
    /// `nil` takes the type from the file's extension.
    public var contentType: String?

    public init(path: String, status: Int = 200, contentType: String? = nil) {
        self.path = path
        self.status = status
        self.contentType = contentType
    }
}

public struct MapRemote: Hashable, Sendable, Codable {
    /// Where to send requests instead, such as `https://staging.weatherly.dev`. A path in it
    /// replaces the request's path; otherwise the path and query stay.
    public var destination: String

    public init(destination: String) {
        self.destination = destination
    }
}

/// One change a Rewrite rule makes.
public enum Rewrite: Hashable, Sendable, Codable {
    /// Adds the header, or replaces its value if it's there.
    case setHeader(MessagePart, name: String, value: String)
    case removeHeader(MessagePart, name: String)
    /// Adds the query parameter, or replaces its value if it's there.
    case setQueryParameter(name: String, value: String)
    case removeQueryParameter(name: String)
    /// Replaces each piece of a text body that reads `find`.
    case replaceBody(MessagePart, find: String, replace: String)
    case setStatus(Int)

    public var part: MessagePart {
        switch self {
        case .setHeader(let part, _, _), .removeHeader(let part, _), .replaceBody(let part, _, _): part
        case .setQueryParameter, .removeQueryParameter: .request
        case .setStatus: .response
        }
    }
}

public enum MessagePart: String, Hashable, Sendable, Codable {
    case request, response
}

public enum Block: Hashable, Sendable, Codable {
    /// Answers with this status, and a short note that Reqly blocked it.
    case status(Int)
    /// Closes the connection, as a network failure would.
    case closeConnection
}

/// A slower network, for the hosts you choose, so you can see how apps cope.
public struct NetworkConditions: Hashable, Sendable, Codable {
    public var profile: NetworkProfile
    /// Hosts to slow down, such as `api.weatherly.dev` or `*.weatherly.dev`. Empty slows them all.
    public var hosts: [String]

    public init(profile: NetworkProfile = .threeG, hosts: [String] = []) {
        self.profile = profile
        self.hosts = hosts
    }

    public func applies(to host: String) -> Bool {
        let patterns = hosts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return patterns.isEmpty || patterns.contains { Wildcard.matches($0.lowercased(), host.lowercased()) }
    }
}

public struct NetworkProfile: Hashable, Sendable, Codable {
    public var name: String
    /// Bytes a second from servers. `nil` doesn't limit it.
    public var downloadBytesPerSecond: Int?
    /// Bytes a second to servers. `nil` doesn't limit it.
    public var uploadBytesPerSecond: Int?
    /// Milliseconds a round trip to the server takes: half on the way there, half on the way
    /// back. Opening a connection takes one too.
    public var latency: Int
    /// The share of packets the network loses, from 0 to 1. Each loss stalls the connection
    /// for a round trip while the packet is sent again.
    public var packetLoss: Double

    public init(
        name: String, downloadBytesPerSecond: Int?, uploadBytesPerSecond: Int?, latency: Int, packetLoss: Double = 0
    ) {
        self.name = name
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.latency = latency
        self.packetLoss = packetLoss
    }

    /// As Apple's Network Link Conditioner sets them.
    public static let threeG = NetworkProfile(
        name: "3G", downloadBytesPerSecond: 780_000 / 8, uploadBytesPerSecond: 330_000 / 8, latency: 100)
    public static let lte = NetworkProfile(
        name: "LTE", downloadBytesPerSecond: 12_000_000 / 8, uploadBytesPerSecond: 4_000_000 / 8, latency: 50)
    public static let lossy = NetworkProfile(
        name: "Lossy", downloadBytesPerSecond: 1_000_000 / 8, uploadBytesPerSecond: 1_000_000 / 8, latency: 300,
        packetLoss: 0.05)

    public static let presets: [NetworkProfile] = [.threeG, .lte, .lossy]
}

/// Every rule, with a switch for each kind, as the Rules window sets them.
public struct RuleSet: Hashable, Sendable, Codable {
    public var rules: [Rule]
    /// The kinds that are on. A rule acts only when its kind is on, as well as the rule itself.
    public var kindsOn: Set<RuleKind>
    public var network: NetworkConditions

    public init(rules: [Rule] = [], kindsOn: Set<RuleKind> = [], network: NetworkConditions = NetworkConditions()) {
        self.rules = rules
        self.kindsOn = kindsOn
        self.network = network
    }

    /// The rules that act on a request, in the order they're listed.
    public func matching(method: String, host: String, port: Int, target: String) -> [Rule] {
        rules.filter {
            $0.isOn && kindsOn.contains($0.kind)
                && $0.match.matches(method: method, host: host, port: port, target: target)
        }
    }

    /// The network conditions for a host, if slow network is on for it.
    public func networkConditions(for host: String) -> NetworkProfile? {
        kindsOn.contains(.slowNetwork) && network.applies(to: host) ? network.profile : nil
    }

    public var isEmpty: Bool { rules.isEmpty && !kindsOn.contains(.slowNetwork) }
}

/// A rule that acted on an exchange, and what it did.
public struct AppliedRule: Hashable, Sendable, Codable {
    public var name: String
    public var kind: RuleKind
    /// Such as "Sent to https://staging.weatherly.dev/v2/forecast".
    public var detail: String

    public init(name: String, kind: RuleKind, detail: String) {
        self.name = name
        self.kind = kind
        self.detail = detail
    }
}

/// A request or a response held at a breakpoint, as it will go on unless you change it.
public enum PausedMessage: Hashable, Sendable {
    case request(RequestHead, body: Data)
    case response(ResponseHead, body: Data)

    public var part: MessagePart {
        switch self {
        case .request: .request
        case .response: .response
        }
    }
}

/// What a paused exchange does next.
public enum PausedDecision: Hashable, Sendable {
    /// Goes on with this request or response, edited or not.
    case resume(PausedMessage)
    /// Stops here. The app gets an error.
    case cancel
}

// MARK: - Saving

// Rules are saved as JSON that reads plainly, such as `{"type": "breakpoint", "phase": "response"}`,
// rather than in the shape Swift would pick for enums.

extension RuleAction {
    private enum CodingKeys: String, CodingKey {
        case type, phase, path, status, contentType, destination, changes, answer, code
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(RuleKind.self, forKey: .type) {
        case .breakpoint:
            self = .breakpoint(try container.decode(BreakpointPhase.self, forKey: .phase))
        case .mapLocal:
            self = .mapLocal(
                MapLocal(
                    path: try container.decode(String.self, forKey: .path),
                    status: try container.decodeIfPresent(Int.self, forKey: .status) ?? 200,
                    contentType: try container.decodeIfPresent(String.self, forKey: .contentType)))
        case .mapRemote:
            self = .mapRemote(MapRemote(destination: try container.decode(String.self, forKey: .destination)))
        case .rewrite:
            self = .rewrite(try container.decode([Rewrite].self, forKey: .changes))
        case .block:
            switch try container.decode(String.self, forKey: .answer) {
            case "status": self = .block(.status(try container.decode(Int.self, forKey: .status)))
            case "closeConnection": self = .block(.closeConnection)
            case let answer:
                throw DecodingError.dataCorruptedError(
                    forKey: .answer, in: container, debugDescription: "No block answers with “\(answer)”.")
            }
        case .script:
            self = .script(Script(code: try container.decode(String.self, forKey: .code)))
        case .slowNetwork:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Slow network isn't a rule of its own.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        switch self {
        case .breakpoint(let phase):
            try container.encode(phase, forKey: .phase)
        case .mapLocal(let local):
            try container.encode(local.path, forKey: .path)
            try container.encode(local.status, forKey: .status)
            try container.encodeIfPresent(local.contentType, forKey: .contentType)
        case .mapRemote(let remote):
            try container.encode(remote.destination, forKey: .destination)
        case .rewrite(let changes):
            try container.encode(changes, forKey: .changes)
        case .block(.status(let code)):
            try container.encode("status", forKey: .answer)
            try container.encode(code, forKey: .status)
        case .block(.closeConnection):
            try container.encode("closeConnection", forKey: .answer)
        case .script(let script):
            try container.encode(script.code, forKey: .code)
        }
    }
}

extension Rewrite {
    private enum CodingKeys: String, CodingKey {
        case type, part, name, value, find, replace, status
    }

    private enum Change: String, Codable {
        case setHeader, removeHeader, setQueryParameter, removeQueryParameter, replaceBody, setStatus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) throws -> String { try container.decode(String.self, forKey: key) }
        func part() throws -> MessagePart { try container.decode(MessagePart.self, forKey: .part) }
        switch try container.decode(Change.self, forKey: .type) {
        case .setHeader: self = .setHeader(try part(), name: try string(.name), value: try string(.value))
        case .removeHeader: self = .removeHeader(try part(), name: try string(.name))
        case .setQueryParameter: self = .setQueryParameter(name: try string(.name), value: try string(.value))
        case .removeQueryParameter: self = .removeQueryParameter(name: try string(.name))
        case .replaceBody: self = .replaceBody(try part(), find: try string(.find), replace: try string(.replace))
        case .setStatus: self = .setStatus(try container.decode(Int.self, forKey: .status))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setHeader(let part, let name, let value):
            try container.encode(Change.setHeader, forKey: .type)
            try container.encode(part, forKey: .part)
            try container.encode(name, forKey: .name)
            try container.encode(value, forKey: .value)
        case .removeHeader(let part, let name):
            try container.encode(Change.removeHeader, forKey: .type)
            try container.encode(part, forKey: .part)
            try container.encode(name, forKey: .name)
        case .setQueryParameter(let name, let value):
            try container.encode(Change.setQueryParameter, forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(value, forKey: .value)
        case .removeQueryParameter(let name):
            try container.encode(Change.removeQueryParameter, forKey: .type)
            try container.encode(name, forKey: .name)
        case .replaceBody(let part, let find, let replace):
            try container.encode(Change.replaceBody, forKey: .type)
            try container.encode(part, forKey: .part)
            try container.encode(find, forKey: .find)
            try container.encode(replace, forKey: .replace)
        case .setStatus(let code):
            try container.encode(Change.setStatus, forKey: .type)
            try container.encode(code, forKey: .status)
        }
    }
}

extension RuleSet {
    private enum CodingKeys: String, CodingKey {
        case rules, kindsOn, network
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        kindsOn = Set(try container.decodeIfPresent([RuleKind].self, forKey: .kindsOn) ?? [])
        network = try container.decodeIfPresent(NetworkConditions.self, forKey: .network) ?? NetworkConditions()
    }

    /// The kinds that are on go in a fixed order, so saving the same rules writes the same file.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rules, forKey: .rules)
        try container.encode(RuleKind.allCases.filter(kindsOn.contains), forKey: .kindsOn)
        try container.encode(network, forKey: .network)
    }
}
