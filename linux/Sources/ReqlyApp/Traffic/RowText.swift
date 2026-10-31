import Presentation
import ReqlyModel

/// What each of a row's columns says, from its exchange's summary, as Windows' list says it.
struct RowText: Equatable {
    var app: String
    var method: String
    /// The host, with the port when it isn't the scheme's own, such as `localhost:8080`.
    var host: String
    /// The path and query, or what an encrypted connection is.
    var path: String
    /// The code, such as 200, or Failed or Paused. An encrypted connection and a request in
    /// progress have none.
    var status: String
    /// What the response's body weighed, once it's arriving or done.
    var size: String
    /// Whether it's an encrypted connection Reqly passed through, which shows a lock in place of
    /// its status.
    var showsLock: Bool
    /// The status in words, for screen readers, which read the lock as these words.
    var statusDescription: String

    init(_ summary: ExchangeSummary) {
        let isTunnel = summary.kind == .tunnel
        app = summary.source?.name ?? summary.device?.name ?? ""
        method = summary.method
        let isDefaultPort = summary.port == (summary.scheme == "https" ? 443 : summary.scheme == "http" ? 80 : nil)
        host = isDefaultPort ? summary.host : "\(summary.host):\(summary.port)"
        path = isTunnel ? "Encrypted connection" : summary.target
        size = summary.bytesReceived > 0 || summary.state == .completed ? ByteCount.text(summary.bytesReceived) : ""
        switch summary.state {
        case .failed:
            status = "Failed"
            statusDescription = "Failed"
            showsLock = false
        case .paused:
            status = "Paused"
            statusDescription = "Paused at a breakpoint"
            showsLock = false
        case .open where isTunnel:
            status = ""
            statusDescription = "Encrypted connection, open"
            showsLock = true
        default:
            status = isTunnel ? "" : summary.status.map(String.init) ?? ""
            statusDescription = isTunnel ? "Encrypted connection" : summary.status.map(String.init) ?? "In progress"
            showsLock = isTunnel
        }
    }
}
