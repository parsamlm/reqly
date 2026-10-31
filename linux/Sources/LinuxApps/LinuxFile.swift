import Glibc

/// Plain reads of the small files and folders Linux describes itself with, in `/proc` and
/// `/sys`, without Foundation's overhead, since a lookup reads many of them.
enum LinuxFile {
    /// What reading a folder found.
    enum Listing {
        case names([String])
        /// It's there, but this user may not read it, as another user's or a hidden process's
        /// `/proc/<pid>/fd` is.
        case denied
        case missing
    }

    /// A small file's bytes, such as one in `/proc`, which says it's empty, so it's read until it
    /// ends, up to `limit` bytes.
    static func bytes(_ path: String, limit: Int = 1 << 20) -> [UInt8]? {
        let file = open(path, O_RDONLY | O_CLOEXEC)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var result: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while result.count < limit {
            let count = chunk.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            result.append(contentsOf: chunk[..<count])
        }
        return result.count > limit ? Array(result.prefix(limit)) : result
    }

    /// A small file's text, read as UTF-8.
    static func text(_ path: String, limit: Int = 1 << 20) -> String? {
        bytes(path, limit: limit).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Where a symbolic link points, as it's written.
    static func link(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 4097)
        let count = readlink(path, &buffer, 4096)
        guard count > 0 else { return nil }
        return String(decoding: buffer[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The names in a folder, without `.` and `..`, and which of them are folders.
    static func entries(in folder: String) -> (listing: Listing, folders: Set<String>) {
        guard let directory = opendir(folder) else {
            return (errno == EACCES || errno == EPERM ? .denied : .missing, [])
        }
        defer { closedir(directory) }
        var names: [String] = []
        var folders: Set<String> = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard name != ".", name != ".." else { continue }
            names.append(name)
            let type = Int32(entry.pointee.d_type)
            if type == Int32(DT_DIR) || (type == Int32(DT_UNKNOWN) && isFolder(folder + "/" + name)) {
                folders.insert(name)
            }
        }
        return (.names(names), folders)
    }

    /// The names in a folder, or none when it can't be read.
    static func names(in folder: String) -> [String] {
        if case .names(let names) = entries(in: folder).listing { names } else { [] }
    }

    /// Whether the path is a folder, following links.
    static func isFolder(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// The inode of the file or folder at `path`, following links.
    static func inode(_ path: String) -> UInt64? {
        var info = stat()
        return stat(path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    /// When the file or folder at `path` last changed, in nanoseconds, or `nil` when it's not there.
    static func modified(_ path: String) -> Int64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Int64(info.st_mtim.tv_sec) * 1_000_000_000 + Int64(info.st_mtim.tv_nsec)
    }

    /// Whether `path` is a file this user may run.
    static func isProgram(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0
    }

    /// The path with every link followed, as realpath(3) gives it.
    static func resolved(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// The last part of a path, such as `curl` for `/usr/bin/curl`.
    static func fileName(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// The folder a path is in, such as `/usr/bin` for `/usr/bin/curl`.
    static func folder(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }
}
