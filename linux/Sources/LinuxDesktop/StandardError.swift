import Glibc

/// Reqly's standard error, for its notes and the command line's messages, written with write(2)
/// as they come. What can't be written is dropped, as once the terminal Reqly was started from has
/// closed, or a log's disk is full: FileHandle's write would stop Reqly instead, maybe before it
/// puts your proxy settings back.
public enum StandardError {
    public static func write(_ text: String) {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { Glibc.write(STDERR_FILENO, $0.baseAddress, $0.count) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { return }
            bytes = bytes.dropFirst(written)
        }
    }
}
