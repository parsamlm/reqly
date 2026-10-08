import Foundation

/// How a gRPC call ended. The server sends it in the `grpc-status` and `grpc-message` trailers,
/// so a call can fail even when its HTTP status is 200.
public struct GRPCStatus: Hashable, Sendable {
    public var code: Int
    /// What the server said about it, if anything.
    public var message: String?

    public init(code: Int, message: String? = nil) {
        self.code = code
        self.message = message
    }

    /// The status in a response's trailers, or in its headers when the call ended without a
    /// body, as gRPC allows.
    public init?(response: ResponseHead?, trailers: Headers?) {
        guard let fields = [trailers, response?.headers].compactMap({ $0 }).first(where: { $0["grpc-status"] != nil })
        else { return nil }
        self.init(fields: fields)
    }

    /// The status in `grpc-status` and `grpc-message` fields, wherever they came from.
    public init?(fields: Headers) {
        guard let text = fields["grpc-status"], let code = Int(text.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        self.code = code
        // The message is percent-encoded, so it can hold any text.
        let message = fields["grpc-message"].map { $0.removingPercentEncoding ?? $0 }
        self.message = message?.isEmpty == false ? message : nil
    }

    /// The code's name, such as `NOT_FOUND`.
    public var name: String {
        Self.names.indices.contains(code) ? Self.names[code] : "Code \(code)"
    }

    /// The code in words, such as "Not found".
    public var title: String {
        Self.titles.indices.contains(code) ? Self.titles[code] : "Code \(code)"
    }

    /// Whether the call succeeded, or failed because of what the app sent, like a 4xx, or
    /// because of the server, like a 5xx.
    public var statusClass: StatusClass {
        switch code {
        case 0: .success
        case 1, 3, 5, 6, 7, 8, 9, 10, 11, 16: .clientError
        default: .serverError
        }
    }

    private static let names = [
        "OK", "CANCELLED", "UNKNOWN", "INVALID_ARGUMENT", "DEADLINE_EXCEEDED", "NOT_FOUND", "ALREADY_EXISTS",
        "PERMISSION_DENIED", "RESOURCE_EXHAUSTED", "FAILED_PRECONDITION", "ABORTED", "OUT_OF_RANGE",
        "UNIMPLEMENTED", "INTERNAL", "UNAVAILABLE", "DATA_LOSS", "UNAUTHENTICATED",
    ]

    private static let titles = [
        "OK", "Cancelled", "Unknown", "Invalid argument", "Deadline exceeded", "Not found", "Already exists",
        "Permission denied", "Resource exhausted", "Failed precondition", "Aborted", "Out of range",
        "Unimplemented", "Internal", "Unavailable", "Data loss", "Unauthenticated",
    ]
}
