import Foundation

/// A folder of made-up files for a test, such as desktop entries, a `/proc` or a cgroup tree,
/// removed when the test ends.
final class Fixture {
    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "reqly-apps-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    /// The full path of `path` in the fixture.
    func path(_ path: String) -> String {
        root + (path.hasPrefix("/") ? path : "/" + path)
    }

    /// Writes a file, making its folders, and returns its full path.
    @discardableResult
    func write(_ path: String, _ contents: String, executable: Bool = false) throws -> String {
        try write(path, Data(contents.utf8), executable: executable)
    }

    @discardableResult
    func write(_ path: String, _ data: Data, executable: Bool = false) throws -> String {
        let full = self.path(path)
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: full))
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: full)
        }
        return full
    }

    /// Makes a folder and its parents, and returns its full path.
    @discardableResult
    func folder(_ path: String) throws -> String {
        let full = self.path(path)
        try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    /// Makes a symbolic link at `path` to `destination`, as written, which needn't exist.
    func link(_ path: String, to destination: String) throws {
        let full = self.path(path)
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: full, withDestinationPath: destination)
    }

    /// The inode of a file or folder in the fixture.
    func inode(_ path: String) -> UInt64 {
        var info = stat()
        _ = stat(self.path(path), &info)
        return UInt64(info.st_ino)
    }

    /// A process in a made-up `/proc` at `proc`: its program, arguments, open sockets and start
    /// time. A process whose program is `nil` has no `exe` link, as if it hid it.
    func process(
        _ pid: Int32, program: String?, arguments: [String], sockets: [UInt64] = [], started: UInt64 = 1000,
        comm: String? = nil, proc: String = "proc"
    ) throws {
        let base = "\(proc)/\(pid)"
        if let program {
            try link(base + "/exe", to: program)
        }
        let file = (program ?? arguments.first ?? "?").split(separator: "/").last.map(String.init) ?? "?"
        let name = comm ?? String(file.prefix(15))
        try write(base + "/comm", name + "\n")
        try write(base + "/cmdline", Data(arguments.joined(separator: "\0").utf8 + [0]))
        try write(
            base + "/stat", "\(pid) (\(name)) S 1 \(pid) \(pid) 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 \(started) 0 0\n")
        try folder(base + "/fd")
        try link(base + "/fd/0", to: "/dev/null")
        for (offset, inode) in sockets.enumerated() {
            try link(base + "/fd/\(offset + 3)", to: "socket:[\(inode)]")
        }
    }

    /// A cgroup in a made-up cgroup tree at `cgroups`, with these processes, and its ID.
    @discardableResult
    func cgroup(_ path: String, processes: [Int32], cgroups: String = "cgroup") throws -> UInt64 {
        try write(cgroups + path + "/cgroup.procs", processes.map(String.init).joined(separator: "\n") + "\n")
        return inode(cgroups + path)
    }
}
