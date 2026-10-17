import ReqlyModel

/// What a request's details say about decryption: it decides the note shown with them, and the
/// action that fits, such as decrypting the host.
public enum DecryptionSituation: Sendable, Hashable {
    /// Plain HTTP, or a tunnel that failed before anything was encrypted.
    case plain
    /// An encrypted connection that passes through untouched.
    case encryptedTunnel
    case decrypted
    /// The app didn't accept Reqly's certificate on a host Reqly decrypts.
    case certificateRejected

    public init(_ exchange: Exchange) {
        switch (exchange.kind, exchange.state) {
        case (.tunnel, .failed(let failure)) where failure.isDecryptionFailure: self = .certificateRejected
        case (.tunnel, .failed): self = .plain
        case (.tunnel, _): self = .encryptedTunnel
        case (.http, _): self = exchange.isDecrypted ? .decrypted : .plain
        }
    }
}
