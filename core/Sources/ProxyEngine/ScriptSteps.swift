import Foundation
import NIOHTTP1
import ReqlyModel
import Scripts

/// What became of a request after its scripts ran.
enum ScriptedRequest {
    /// It goes on like this.
    case send(ScriptRequest)
    /// A script answered it, so it never reaches the server.
    case answer(ScriptResponse)
}

extension EngineContext {
    /// Runs each script's `onRequest` in turn, each on the request the one before left, and
    /// records what each did. A script that fails leaves the request as it was.
    func runRequestScripts(
        _ scripts: [(rule: Rule, script: Script)], on request: ScriptRequest, for exchange: ExchangeID
    ) async -> ScriptedRequest {
        var current = request
        for (rule, script) in scripts {
            let run = await ScriptRunner.shared.run(script, on: current, shared: sharedState(of: rule))
            let detail: String
            switch run.outcome {
            case _ where run.error != nil:
                detail = "Failed: \(run.error!) The request went on as it was."
            case .answer(let answer):
                record(run, of: rule, on: .request, for: exchange, detail: "Answered with \(answer.status).")
                return .answer(answer)
            case .request(let changed):
                if Destination(url: changed.url) == nil {
                    detail = "Failed: “\(changed.url)” isn't an http or https URL. The request went on as it was."
                } else {
                    detail = ScriptChanges.describe(from: current, to: changed)
                    current = changed
                }
            case .unchanged, .response:
                detail = "Ran, and changed nothing."
            }
            record(run, of: rule, on: .request, for: exchange, detail: detail)
        }
        return .send(current)
    }

    /// Runs each script's `onResponse` in turn, and records what each did. A script that fails
    /// leaves the response as it was.
    func runResponseScripts(
        _ scripts: [(rule: Rule, script: Script)], on response: ScriptResponse, to request: ScriptRequest,
        for exchange: ExchangeID
    ) async -> ScriptResponse {
        var current = response
        for (rule, script) in scripts {
            let run = await ScriptRunner.shared.run(script, on: current, to: request, shared: sharedState(of: rule))
            let detail: String
            if let error = run.error {
                detail = "Failed: \(error) The response went on as it was."
            } else if case .response(let changed) = run.outcome {
                detail = ScriptChanges.describe(from: current, to: changed)
                current = changed
            } else {
                detail = "Ran, and changed nothing."
            }
            record(run, of: rule, on: .response, for: exchange, detail: detail)
        }
        return current
    }

    private func record(_ run: ScriptRun, of rule: Rule, on part: MessagePart, for exchange: ExchangeID, detail: String)
    {
        if let shared = run.shared {
            setSharedState(shared, of: rule)
        }
        emit(.ruleApplied(exchange, AppliedRule(name: rule.name, kind: .script, detail: detail)))
        if !run.logs.isEmpty {
            emit(.scriptOutput(exchange, ScriptOutput(rule: rule.name, part: part, lines: run.logs)))
        }
    }
}

extension ScriptRequest {
    /// A request on its way to the server, as a script sees it.
    init(_ head: HTTPRequestHead, destination: Destination, body: Data) {
        self.init(method: head.method.rawValue, url: destination.url, headers: Headers(head.headers), body: body)
    }

    /// The head that goes to the server, and where it goes, as the script left them. When the
    /// URL names another server, the Host header follows it, unless the script set it.
    func applied(to head: HTTPRequestHead, destination: Destination) -> (HTTPRequestHead, Destination) {
        var head = head
        let before = Headers(head.headers)
        head.method = HTTPMethod(rawValue: method)
        head.headers = HTTPHeaders(headers.map { ($0.name, $0.value) })
        guard url != destination.url, let moved = Destination(url: url) else { return (head, destination) }
        head.uri = moved.originForm
        if before["Host"] == headers["Host"] {
            head.headers.replaceOrAdd(name: "Host", value: moved.hostHeader)
        }
        return (head, moved)
    }
}

extension ScriptResponse {
    init(_ head: HTTPResponseHead, body: Data) {
        self.init(
            status: Int(head.status.code), reason: head.status.reasonPhrase, headers: Headers(head.headers), body: body)
    }

    /// The head as the script left it. A new status gets its own reason, unless the script
    /// gave one.
    func applied(to head: HTTPResponseHead) -> HTTPResponseHead {
        var head = head
        let keepsReason = Int(head.status.code) != status && reason == head.status.reasonPhrase
        let phrase = keepsReason || reason.isEmpty ? HTTPResponseStatus(statusCode: status).reasonPhrase : reason
        head.status = HTTPResponseStatus(statusCode: status, reasonPhrase: phrase)
        head.headers = HTTPHeaders(headers.map { ($0.name, $0.value) })
        return head
    }

    /// A response a script made up to answer a request with.
    var head: HTTPResponseHead {
        applied(to: HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: status)))
    }
}

extension Destination {
    /// Where an `http` or `https` URL points, or `nil` for anything else.
    init?(url: String) {
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https", let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        var originForm = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery {
            originForm += "?" + query
        }
        self.init(
            scheme: scheme, authority: Authority(host: host, port: components.port ?? (scheme == "https" ? 443 : 80)),
            originForm: originForm)
    }
}
