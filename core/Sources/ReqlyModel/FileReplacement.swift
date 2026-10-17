import Foundation

/// Saving a file in one step, so whoever reads it finds the old file or the new one, never part of
/// one, as Reqly saves its settings and sessions.
public enum FileReplacement {
    /// Writes `data` to `url`, making its folder when it's missing.
    public static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try retrying { try data.write(to: url, options: .atomic) }
    }

    /// Runs `step`, which puts a new file in an old one's place, again for up to about a second
    /// while it fails. On Windows, antivirus software and the search indexer open new files to read
    /// them, and a file can't take another's place while one of them has it open. Other tools on
    /// Windows, such as Git and npm, wait for them in the same way. Elsewhere, `step` runs once.
    public static func retrying<Result>(_ step: () throws -> Result) throws -> Result {
        #if os(Windows)
            var wait = 0.01
            while wait < 0.5 {
                do {
                    return try step()
                } catch {
                    Thread.sleep(forTimeInterval: wait)
                    wait *= 2
                }
            }
        #endif
        return try step()
    }
}
