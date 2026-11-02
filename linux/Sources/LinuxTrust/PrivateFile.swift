import Foundation

/// Why something Reqly does with its certificate on Linux didn't work, in words for the app to show.
struct TrustFailure: Error, LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Files Reqly writes with the modes it chooses, whatever the process's umask, and reads only
/// when they're safe. Foundation's atomic write makes files everyone can read (0644) on Linux, so
/// it won't do for a key.
enum PrivateFile {
    /// Writes `data` to `url` with `mode`, such as 0600 for a key or 0644 for a certificate, in
    /// a new file that then takes the old one's place, so a reader never sees half of it. Its
    /// folder is made when it's missing, and only you can open it (0700).
    static func write(_ data: Data, to url: URL, mode: mode_t) throws(TrustFailure) {
        let folder = url.deletingLastPathComponent()
        try makeFolder(folder)
        let temporary = folder.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)").path
        let fd = open(temporary, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw failure("make", temporary) }
        var done = false
        defer {
            if !done { unlink(temporary) }
        }
        // The umask may have taken bits off.
        var ok = fchmod(fd, mode) == 0
        ok =
            ok
            && data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Glibc.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
        ok = ok && fsync(fd) == 0
        let error = errno
        close(fd)
        guard ok else {
            errno = error
            throw failure("write", url.path)
        }
        guard rename(temporary, url.path) == 0 else { throw failure("replace", url.path) }
        done = true
        // The new name lasts through a power cut once the folder is on disk too.
        let folderFD = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if folderFD >= 0 {
            fsync(folderFD)
            close(folderFD)
        }
    }

    /// What a private file holds, for the words Reqly shows when it won't read the file.
    struct Contents: Sendable {
        /// Such as "its certificate's key".
        var name: String
        /// How to start again without the file, such as "remove Reqly's certificate in
        /// Settings › HTTPS and set up HTTPS again".
        var startingAgain: String

        static let certificateKey = Contents(
            name: "its certificate's key",
            startingAgain: "remove Reqly's certificate in Settings › HTTPS and set up HTTPS again")
        static let secrets = Contents(
            name: "the passwords and keys it keeps",
            startingAgain: "delete the file and enter them again in Settings › Connections")
    }

    /// The contents of a file only you can read, or `nil` when there's no file. As ssh does with
    /// keys, it refuses a file that's someone else's, or that others can read or change.
    static func readOwn(_ url: URL, holding contents: Contents = .certificateKey) throws(TrustFailure) -> Data? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw failure("open", url.path)
        }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw failure("open", url.path) }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw TrustFailure(message: "\(url.path) isn't a file, so Reqly can't read \(contents.name) from it.")
        }
        guard status.st_uid == geteuid() else {
            throw TrustFailure(
                message: """
                    Reqly didn't use \(contents.name), because another account owns the file \
                    \(url.path). To start again, \(contents.startingAgain).
                    """)
        }
        guard status.st_mode & 0o077 == 0 else {
            throw TrustFailure(
                message: """
                    Reqly didn't use \(contents.name), because others can read the file \
                    \(url.path). Make it yours alone with chmod 600, or, to start again, \
                    \(contents.startingAgain).
                    """)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw failure("read", url.path) }
            if count == 0 { return data }
            data.append(contentsOf: buffer[..<count])
        }
    }

    /// Deletes the file at `url`, if there is one.
    static func remove(_ url: URL) throws(TrustFailure) {
        guard unlink(url.path) == 0 || errno == ENOENT else { throw failure("delete", url.path) }
    }

    /// Makes `folder` if it's missing, and its parents, then makes it yours alone (0700).
    static func makeFolder(_ folder: URL) throws(TrustFailure) {
        do {
            try FileManager.default.createDirectory(
                at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw TrustFailure(message: "Reqly couldn't make the folder \(folder.deletingLastPathComponent().path).")
        }
        guard mkdir(folder.path, 0o700) == 0 || errno == EEXIST else { throw failure("make", folder.path) }
        guard chmod(folder.path, 0o700) == 0 else { throw failure("protect", folder.path) }
    }

    private static func failure(_ action: String, _ path: String) -> TrustFailure {
        TrustFailure(message: "Reqly couldn't \(action) \(path): \(String(cString: strerror(errno))).")
    }
}
