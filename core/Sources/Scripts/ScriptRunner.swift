import CQuickJS
import Foundation
import ReqlyModel
import Synchronization

/// A request as a script sees it, and as it goes on afterwards.
public struct ScriptRequest: Hashable, Sendable {
    public var method: String
    public var url: String
    public var headers: Headers
    public var body: Data

    public init(method: String, url: String, headers: Headers, body: Data) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// A response as a script sees it, and as it goes on afterwards.
public struct ScriptResponse: Hashable, Sendable {
    public var status: Int
    public var reason: String
    public var headers: Headers
    public var body: Data

    public init(status: Int, reason: String, headers: Headers, body: Data) {
        self.status = status
        self.reason = reason
        self.headers = headers
        self.body = body
    }
}

/// What one run of a script came to.
public struct ScriptRun: Sendable {
    public enum Outcome: Hashable, Sendable {
        /// The script has no function for this part, or didn't change anything.
        case unchanged
        /// The request goes on like this.
        case request(ScriptRequest)
        /// `onRequest` answered the request itself, so it never reaches the server.
        case answer(ScriptResponse)
        /// The response goes on like this.
        case response(ScriptResponse)
    }

    public var outcome: Outcome = .unchanged
    /// What the script printed with `console.log`.
    public var logs: [String] = []
    /// Why the script failed, with the line it failed on. The message goes on unchanged.
    public var error: String?
    /// The script's `shared` object, as JSON, for its next run.
    public var shared: String?
    /// How long the script ran, without the wait for a worker to run it.
    public var duration: Duration = .zero
}

/// Runs scripts in QuickJS-ng. Each run gets a fresh context, with no way to reach files, the
/// network or other processes, and a time limit. Runs happen on worker threads of Reqly's own,
/// whose stacks are big enough for QuickJS's stack limit.
public final class ScriptRunner: Sendable {
    /// How long one run may take.
    public static let timeLimit: Double = 1
    /// Bodies bigger than this reach scripts as `null`, and go on unchanged.
    public static let bodyLimit = 8 << 20
    static let memoryLimit = 128 << 20
    static let stackLimit = 1 << 20
    static let threadStack = 8 << 20

    private let workers: [Worker]

    /// The runner every proxy shares. Its threads start the first time a script runs.
    public static let shared = ScriptRunner()

    /// - Parameter workers: How many scripts can run at once.
    public init(workers count: Int = 4) {
        workers = (0..<max(1, count)).map { Worker(number: $0) }
    }

    /// Runs the script's `onRequest` on a request.
    public func run(_ script: Script, on request: ScriptRequest, shared: String? = nil) async -> ScriptRun {
        let input = Self.input(phase: .request, request: request, response: nil, shared: shared)
        let (failed, text, duration) = await run(script.code, input: input)
        return Self.parse(text, failed: failed, duration: duration, request: request, response: nil)
    }

    /// Runs the script's `onResponse` on a response, which answers `request`.
    public func run(
        _ script: Script, on response: ScriptResponse, to request: ScriptRequest, shared: String? = nil
    ) async -> ScriptRun {
        let input = Self.input(phase: .response, request: request, response: response, shared: shared)
        let (failed, text, duration) = await run(script.code, input: input)
        return Self.parse(text, failed: failed, duration: duration, request: request, response: response)
    }

    /// The script's syntax error, with its line, or `nil` when it compiles.
    public func check(_ code: String) async -> String? {
        await withCheckedContinuation { continuation in
            worker.submit { runtime in
                guard let runtime else {
                    continuation.resume(returning: Self.noEngine)
                    return
                }
                var result: UnsafeMutablePointer<CChar>?
                var length = 0
                let failed = code.withCString { reqly_check(runtime, $0, strlen($0), &result, &length) }
                let text = Self.take(result, length: length)
                continuation.resume(returning: failed == 0 ? nil : Self.explain(text))
            }
        }
    }

    /// The worker with the fewest jobs, so a script that runs long holds up as few others as can be.
    private var worker: Worker {
        workers.min { $0.load < $1.load } ?? workers[0]
    }

    private func run(_ code: String, input: String) async -> (failed: Bool, text: String, duration: Duration) {
        await withCheckedContinuation { continuation in
            worker.submit { runtime in
                guard let runtime else {
                    continuation.resume(returning: (true, Self.noEngine, .zero))
                    return
                }
                let started = ContinuousClock.now
                var result: UnsafeMutablePointer<CChar>?
                var length = 0
                let failed = Prelude.source.withCString { prelude in
                    code.withCString { script in
                        input.withCString { argument in
                            reqly_run(
                                runtime, prelude, strlen(prelude), script, strlen(script), "__reqly_run", argument,
                                strlen(argument), Self.timeLimit, &result, &length)
                        }
                    }
                }
                let duration = ContinuousClock.now - started
                continuation.resume(returning: (failed != 0, Self.take(result, length: length), duration))
            }
        }
    }

    private static let noEngine = "Reqly couldn't start its script engine."

    private static func take(_ result: UnsafeMutablePointer<CChar>?, length: Int) -> String {
        guard let result else { return "" }
        defer { free(result) }
        return String(decoding: UnsafeRawBufferPointer(start: result, count: length), as: UTF8.self)
    }

    // MARK: - Messages as JSON

    private static func input(
        phase: MessagePart, request: ScriptRequest, response: ScriptResponse?, shared: String?
    ) -> String {
        var input: [String: Any] = [
            "phase": phase.rawValue,
            "request": [
                "method": request.method, "url": request.url, "headers": fields(request.headers),
                "body": text(of: request.body) as Any,
            ],
        ]
        if let response {
            input["response"] = [
                "status": response.status, "reason": response.reason, "headers": fields(response.headers),
                "body": text(of: response.body) as Any,
            ]
        }
        if let shared {
            input["shared"] = shared
        }
        let data = (try? JSONSerialization.data(withJSONObject: input, options: [.fragmentsAllowed])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func fields(_ headers: Headers) -> [[String]] {
        headers.map { [$0.name, $0.value] }
    }

    /// The body as text, or `NSNull` for bytes that aren't text, or too many of them.
    private static func text(of body: Data) -> Any {
        guard body.count <= bodyLimit, let text = String(data: body, encoding: .utf8) else { return NSNull() }
        return text
    }

    private static func parse(
        _ text: String, failed: Bool, duration: Duration, request: ScriptRequest, response: ScriptResponse?
    ) -> ScriptRun {
        var run = ScriptRun(duration: duration)
        guard !failed else {
            run.error = explain(text)
            return run
        }
        guard let output = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            run.error = "Reqly couldn't read what the script returned."
            return run
        }
        run.logs = output["logs"] as? [String] ?? []
        run.shared = output["shared"] as? String
        if let answer = output["answer"] as? [String: Any] {
            run.outcome = .answer(Self.response(answer, original: nil))
        } else if let object = output["request"] as? [String: Any] {
            if let changed = Self.request(object, original: request) {
                run.outcome = .request(changed)
            }
        } else if let object = output["response"] as? [String: Any], let response {
            let changed = Self.response(object, original: response)
            if changed != response {
                run.outcome = .response(changed)
            }
        }
        return run
    }

    /// The request as the script left it, or `nil` when it's what went in.
    private static func request(_ object: [String: Any], original: ScriptRequest) -> ScriptRequest? {
        var request = original
        request.method = (object["method"] as? String ?? original.method).uppercased()
        request.url = object["url"] as? String ?? original.url
        request.headers = headers(object["headers"]) ?? original.headers
        if object["bodyChanged"] as? Bool == true {
            request.body = Data((object["body"] as? String ?? "").utf8)
        }
        return request == original ? nil : request
    }

    private static func response(_ object: [String: Any], original: ScriptResponse?) -> ScriptResponse {
        var response = original ?? ScriptResponse(status: 200, reason: "", headers: Headers(), body: Data())
        if let status = object["status"] as? Int, (100...999).contains(status) {
            response.status = status
        }
        response.reason = object["reason"] as? String ?? response.reason
        response.headers = headers(object["headers"]) ?? response.headers
        if original == nil || object["bodyChanged"] as? Bool == true {
            response.body = Data((object["body"] as? String ?? "").utf8)
        }
        return response
    }

    private static func headers(_ value: Any?) -> Headers? {
        guard let pairs = value as? [[String]] else { return nil }
        return Headers(pairs.compactMap { $0.count == 2 ? HeaderField(name: $0[0], value: $0[1]) : nil })
    }

    /// QuickJS's error, in plain words: the message, and the line in the script where it happened.
    static func explain(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let message = lines.first ?? "The script failed."
        if message.contains("interrupted") {
            return "The script took longer than \(Int(timeLimit)) second, so Reqly stopped it."
        }
        if message.contains("out of memory") {
            return "The script used more memory than Reqly allows, so Reqly stopped it."
        }
        // The first place in the script itself, such as "at onRequest (script.js:3:15)".
        let place =
            lines.dropFirst().first { $0.contains("script.js:") }
            ?? (message.contains("script.js:") ? message : nil)
        guard let place, let range = place.range(of: #"script\.js:(\d+)"#, options: .regularExpression) else {
            return message
        }
        let line = place[range].split(separator: ":").last.map(String.init) ?? ""
        return "\(message), on line \(line)."
    }
}

/// A thread with a QuickJS runtime of its own, which runs the jobs it's given one at a time.
/// A job gets `nil` if the runtime couldn't start.
private final class Worker: Sendable {
    private let jobs = Mutex<[@Sendable (OpaquePointer?) -> Void]>([])
    private let waiting = DispatchSemaphore(value: 0)
    private let busy = Atomic<Int>(0)

    /// The jobs waiting or running.
    var load: Int { busy.load(ordering: .relaxed) }

    init(number: Int) {
        let thread = Thread { [self] in
            // QuickJS checks its stack against the limit, so the thread's stack must be bigger.
            let runtime = reqly_runtime_new(ScriptRunner.memoryLimit, ScriptRunner.stackLimit)
            while true {
                waiting.wait()
                guard let job = jobs.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { continue }
                job(runtime)
                busy.subtract(1, ordering: .relaxed)
            }
        }
        thread.stackSize = ScriptRunner.threadStack
        thread.name = "Reqly Scripts \(number + 1)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func submit(_ job: @escaping @Sendable (OpaquePointer?) -> Void) {
        busy.add(1, ordering: .relaxed)
        jobs.withLock { $0.append(job) }
        waiting.signal()
    }
}
