import ReqlyModel

/// What a script would do to the request or the response of an exchange, for trying it out.
public struct ScriptTrial: Hashable, Sendable {
    public var part: MessagePart
    /// Such as "Changed 1 header." or "Failed: TypeError: …, on line 3."
    public var detail: String
    /// What the script printed with `console.log`.
    public var logs: [String]
    public var failed: Bool

    public init(part: MessagePart, detail: String, logs: [String], failed: Bool) {
        self.part = part
        self.detail = detail
        self.logs = logs
        self.failed = failed
    }
}
