import Foundation
import NIOCore
import NIOHTTP1
import ReqlyModel

/// What the rules do to one exchange, worked out once, when its request arrives.
struct RulePlan {
    /// A Block or Map Local rule answers the request itself, and the server never sees it.
    enum LocalAnswer {
        case block(Rule, Block)
        case mapLocal(Rule, MapLocal)
    }

    var localAnswer: LocalAnswer?
    var mapRemote: (rule: Rule, remote: MapRemote)?
    var rewrites: [(rule: Rule, rewrite: Rewrite)] = []
    var requestBreakpoint: Rule?
    var responseBreakpoint: Rule?
    /// Every matching script runs, in the order they're listed.
    var scripts: [(rule: Rule, script: Script)] = []

    /// The first rule of each kind wins, in the order the rules are listed. A Block rule wins
    /// over Map Local.
    init(_ rules: [Rule]) {
        for rule in rules {
            switch rule.action {
            case .block(let block):
                if case .block = localAnswer {} else { localAnswer = .block(rule, block) }
            case .mapLocal(let local):
                if localAnswer == nil { localAnswer = .mapLocal(rule, local) }
            case .mapRemote(let remote):
                if mapRemote == nil { mapRemote = (rule, remote) }
            case .rewrite(let steps):
                rewrites += steps.map { (rule, $0) }
            case .breakpoint(let phase):
                if phase.pausesRequest, requestBreakpoint == nil { requestBreakpoint = rule }
                if phase.pausesResponse, responseBreakpoint == nil { responseBreakpoint = rule }
            case .script(let script):
                scripts.append((rule, script))
            }
        }
    }

    var requestRewrites: [(rule: Rule, rewrite: Rewrite)] { rewrites.filter { $0.rewrite.part == .request } }
    var responseRewrites: [(rule: Rule, rewrite: Rewrite)] { rewrites.filter { $0.rewrite.part == .response } }

    var requestScripts: [(rule: Rule, script: Script)] { scripts.filter { $0.script.runsOnRequest } }
    var responseScripts: [(rule: Rule, script: Script)] { scripts.filter { $0.script.runsOnResponse } }

    /// A breakpoint, a body rewrite or a script needs the whole request before it goes on.
    var holdsRequest: Bool {
        requestBreakpoint != nil || requestRewrites.contains { $0.rewrite.changesBody } || !requestScripts.isEmpty
    }

    /// A breakpoint, a body rewrite or a script needs the whole response before the app gets
    /// it. It also asks the server not to compress the response, so its text can be read and
    /// changed.
    var holdsResponse: Bool {
        responseBreakpoint != nil || responseRewrites.contains { $0.rewrite.changesBody } || !responseScripts.isEmpty
    }
}

/// How Reqly answers a request itself, for a Block or Map Local rule.
enum LocalReply {
    case respond(status: Int, contentType: String, body: Data)
    /// Closes the connection, as a failing network would.
    case closeConnection(rule: String)
}

extension RulePlan.LocalAnswer {
    /// Works out the answer, and what the rule did, and hands both to `done` on `loop`. Map
    /// Local reads its file away from the event loop, which mustn't wait on the disk.
    func reply(on loop: any EventLoop, _ done: @escaping @Sendable (LocalReply, AppliedRule) -> Void) {
        switch self {
        case .block(let rule, .status(let code)):
            let note = "Reqly blocked this request with the rule “\(rule.name)”.\n"
            done(
                .respond(status: code, contentType: "text/plain; charset=utf-8", body: Data(note.utf8)),
                AppliedRule(name: rule.name, kind: .block, detail: "Answered with \(code)."))
        case .block(let rule, .closeConnection):
            done(
                .closeConnection(rule: rule.name),
                AppliedRule(name: rule.name, kind: .block, detail: "Closed the connection."))
        case .mapLocal(let rule, let local):
            let path = (local.path as NSString).expandingTildeInPath
            DispatchQueue.global(qos: .userInitiated).async {
                let file = try? Data(contentsOf: URL(fileURLWithPath: path))
                loop.execute {
                    if let file {
                        let name = (path as NSString).lastPathComponent
                        done(
                            .respond(
                                status: local.status,
                                contentType: local.contentType ?? RuleActions.contentType(forFile: path), body: file),
                            AppliedRule(name: rule.name, kind: .mapLocal, detail: "Answered with \(name)."))
                    } else {
                        let note = "Reqly couldn't read \(path) for the Map Local rule “\(rule.name)”.\n"
                        done(
                            .respond(status: 500, contentType: "text/plain; charset=utf-8", body: Data(note.utf8)),
                            AppliedRule(name: rule.name, kind: .mapLocal, detail: "Couldn't read \(path)."))
                    }
                }
            }
        }
    }
}

extension Rewrite {
    var changesBody: Bool {
        if case .replaceBody = self { true } else { false }
    }
}

/// Where a request goes: its server, and the path and query to send there.
struct Destination: Equatable {
    var scheme: String
    var authority: Authority
    var originForm: String

    var usesTLS: Bool { scheme == "https" }

    var url: String {
        let host = authority.host.contains(":") ? "[\(authority.host)]" : authority.host
        let isDefaultPort = (scheme == "http" && authority.port == 80) || (scheme == "https" && authority.port == 443)
        return "\(scheme)://\(isDefaultPort ? host : "\(host):\(authority.port)")\(originForm)"
    }

    /// The Host header for this destination.
    var hostHeader: String {
        let host = authority.host.contains(":") ? "[\(authority.host)]" : authority.host
        let isDefaultPort = (scheme == "http" && authority.port == 80) || (scheme == "https" && authority.port == 443)
        return isDefaultPort ? host : "\(host):\(authority.port)"
    }

    /// Where a Map Remote rule sends the request instead. A path in the destination replaces the
    /// request's path; the query stays. `nil` when the destination isn't an http or https URL.
    func mapped(to remote: MapRemote) -> Destination? {
        guard let url = URLComponents(string: remote.destination.trimmingCharacters(in: .whitespaces)),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host, !host.isEmpty
        else { return nil }
        // No local named originForm: older compilers resolve the closure's to it, a circular reference.
        let query = originForm.firstIndex(of: "?").map { String(originForm[$0...]) } ?? ""
        let path = url.percentEncodedPath
        return Destination(
            scheme: scheme,
            authority: Authority(host: host.lowercased(), port: url.port ?? (scheme == "https" ? 443 : 80)),
            originForm: path.isEmpty || path == "/" ? originForm : path + query
        )
    }
}

/// The changes rules make to heads and bodies, each reported as what the rule did.
enum RuleActions {
    static func rewrite(_ head: inout HTTPRequestHead, with rewrites: [(rule: Rule, rewrite: Rewrite)]) -> [AppliedRule]
    {
        var done: [(Rule, String)] = []
        for (rule, rewrite) in rewrites {
            switch rewrite {
            case .setHeader(.request, let name, let value):
                head.headers.replaceOrAdd(name: name, value: value)
                done.append((rule, "Set the \(name) header"))
            case .removeHeader(.request, let name):
                guard head.headers.contains(name: name) else { continue }
                head.headers.remove(name: name)
                done.append((rule, "Removed the \(name) header"))
            case .setQueryParameter(let name, let value):
                head.uri = settingQuery(name, to: value, in: head.uri)
                done.append((rule, "Set the \(name) query parameter"))
            case .removeQueryParameter(let name):
                let uri = settingQuery(name, to: nil, in: head.uri)
                guard uri != head.uri else { continue }
                head.uri = uri
                done.append((rule, "Removed the \(name) query parameter"))
            default:
                continue
            }
        }
        return grouped(done)
    }

    static func rewrite(_ head: inout HTTPResponseHead, with rewrites: [(rule: Rule, rewrite: Rewrite)])
        -> [AppliedRule]
    {
        var done: [(Rule, String)] = []
        for (rule, rewrite) in rewrites {
            switch rewrite {
            case .setStatus(let code):
                head.status = HTTPResponseStatus(statusCode: code)
                done.append((rule, "Set the status to \(code)"))
            case .setHeader(.response, let name, let value):
                head.headers.replaceOrAdd(name: name, value: value)
                done.append((rule, "Set the \(name) header"))
            case .removeHeader(.response, let name):
                guard head.headers.contains(name: name) else { continue }
                head.headers.remove(name: name)
                done.append((rule, "Removed the \(name) header"))
            default:
                continue
            }
        }
        return grouped(done)
    }

    /// Replaces text in a body. It works on bytes, so it finds text in any body, as long as the
    /// body isn't compressed.
    static func rewrite(_ body: inout Data, part: MessagePart, with rewrites: [(rule: Rule, rewrite: Rewrite)])
        -> [AppliedRule]
    {
        var done: [(Rule, String)] = []
        for (rule, rewrite) in rewrites {
            guard case .replaceBody(part, let find, let replace) = rewrite, !find.isEmpty else { continue }
            let count = replaceAll(Data(find.utf8), with: Data(replace.utf8), in: &body)
            if count > 0 {
                done.append(
                    (rule, "Replaced “\(find)” in the \(part.rawValue) body \(count == 1 ? "once" : "\(count) times")"))
            }
        }
        return grouped(done)
    }

    /// What you changed at a breakpoint, such as "You changed the status and the body.", or
    /// `nil` when it went on as it was.
    static func edits(from original: PausedMessage, to edited: PausedMessage) -> String? {
        var changed: [String] = []
        switch (original, edited) {
        case (.request(let before, let beforeBody), .request(let after, let afterBody)):
            if after.method != before.method { changed.append("the method") }
            if after.url != before.url { changed.append("the URL") }
            if after.headers != before.headers { changed.append("the headers") }
            if afterBody != beforeBody { changed.append("the body") }
        case (.response(let before, let beforeBody), .response(let after, let afterBody)):
            if after.status != before.status || after.reason != before.reason { changed.append("the status") }
            if after.headers != before.headers { changed.append("the headers") }
            if afterBody != beforeBody { changed.append("the body") }
        default:
            return nil
        }
        guard let last = changed.last else { return nil }
        let list = changed.count == 1 ? last : changed.dropLast().joined(separator: ", ") + " and " + last
        return "You changed \(list)."
    }

    /// One report for each rule, with everything it did.
    private static func grouped(_ done: [(Rule, String)]) -> [AppliedRule] {
        var order: [UUID] = []
        var details: [UUID: (Rule, [String])] = [:]
        for (rule, detail) in done {
            if details[rule.id] == nil {
                order.append(rule.id)
                details[rule.id] = (rule, [])
            }
            details[rule.id]?.1.append(detail)
        }
        return order.compactMap { id in
            details[id].map {
                AppliedRule(name: $0.0.name, kind: $0.0.kind, detail: $0.1.joined(separator: ". ") + ".")
            }
        }
    }

    @discardableResult
    static func replaceAll(_ find: Data, with replace: Data, in data: inout Data) -> Int {
        var count = 0
        var result = Data()
        var searchStart = data.startIndex
        while let range = data.range(of: find, in: searchStart..<data.endIndex) {
            result.append(data[searchStart..<range.lowerBound])
            result.append(replace)
            searchStart = range.upperBound
            count += 1
        }
        guard count > 0 else { return 0 }
        result.append(data[searchStart..<data.endIndex])
        data = result
        return count
    }

    /// The target with a query parameter set to `value`, or taken out when `value` is `nil`.
    static func settingQuery(_ name: String, to value: String?, in uri: String) -> String {
        let mark = uri.firstIndex(of: "?")
        let path = mark.map { String(uri[..<$0]) } ?? uri
        var pairs = mark.map { String(uri[uri.index(after: $0)...]).split(separator: "&").map(String.init) } ?? []
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        func isNamed(_ pair: String) -> Bool {
            let key = pair.split(separator: "=", maxSplits: 1).first.map(String.init) ?? pair
            return (key.removingPercentEncoding ?? key) == name
        }
        if let value {
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            let pair = "\(encodedName)=\(encodedValue)"
            if let index = pairs.firstIndex(where: isNamed) {
                pairs[index] = pair
                pairs.removeAll { isNamed($0) && $0 != pair }
            } else {
                pairs.append(pair)
            }
        } else {
            pairs.removeAll(where: isNamed)
        }
        return pairs.isEmpty ? path : path + "?" + pairs.joined(separator: "&")
    }

    /// The type of a file Map Local answers with, from its extension.
    static func contentType(forFile path: String) -> String {
        let types = [
            "json": "application/json", "html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8",
            "css": "text/css", "js": "text/javascript", "mjs": "text/javascript", "txt": "text/plain; charset=utf-8",
            "xml": "application/xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
            "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml", "ico": "image/x-icon",
            "pdf": "application/pdf", "mp4": "video/mp4", "mp3": "audio/mpeg", "wasm": "application/wasm",
            "woff": "font/woff", "woff2": "font/woff2",
        ]
        let ext = (path as NSString).pathExtension.lowercased()
        return types[ext] ?? "application/octet-stream"
    }
}
