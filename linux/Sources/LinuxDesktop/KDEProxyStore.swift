import Foundation

/// KDE's proxy setting, in `kioslaverc`'s `[Proxy Settings]` group, changed with Reqly's own
/// editor so the rest of the file stays as it was. Running apps hear about a change through KDE's
/// D-Bus signal.
public struct KDEProxyStore: Sendable {
    /// `~/.config/kioslaverc`, or where `XDG_CONFIG_HOME` puts it.
    public var file: URL
    /// KDE's system-wide files, which can lock the setting: `/etc/xdg/kioslaverc`, or one in each
    /// of `XDG_CONFIG_DIRS`.
    public var systemFiles: [URL]
    /// Whether to tell running apps about a change, which the tests leave off.
    var tellsApps = true

    static let group = ["Proxy Settings"]
    static let keys = (type: "ProxyType", http: "httpProxy", https: "httpsProxy")

    public init(file: URL, systemFiles: [URL] = []) {
        self.file = file
        self.systemFiles = systemFiles
    }

    /// The files for `environment`, such as the process's own.
    public init(environment: [String: String]) {
        let home =
            environment["HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? URL.homeDirectory
        let config =
            environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(filePath: $0) : nil }
            ?? home.appending(path: ".config", directoryHint: .isDirectory)
        let systemFolders = (environment["XDG_CONFIG_DIRS"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }
        self.init(
            file: config.appending(path: "kioslaverc"),
            systemFiles: (systemFolders.isEmpty ? ["/etc/xdg"] : systemFolders).map {
                URL(filePath: String($0), directoryHint: .isDirectory).appending(path: "kioslaverc")
            })
    }

    /// Couldn't read or change the file.
    public struct Failure: LocalizedError, Hashable, CustomStringConvertible {
        public var description: String

        public var errorDescription: String? { description }
    }

    /// Whether the file is there.
    public var fileExists: Bool { FileManager.default.fileExists(atPath: file.path) }

    /// The setting as the file has it.
    public func read() throws -> KDEProxy {
        guard let config = try load() else { return KDEProxy(fileExists: false) }
        return KDEProxy(
            fileExists: true, proxyType: config.value(Self.keys.type, in: Self.group),
            httpProxy: config.value(Self.keys.http, in: Self.group),
            httpsProxy: config.value(Self.keys.https, in: Self.group))
    }

    /// Changes the keys that differ from `settings`, removing those it doesn't have, and tells
    /// running apps. Settings from before the file was there remove it, unless something else has
    /// been added since. Throws ``GNOMEProxyStore/Locked`` when KDE's files lock the setting.
    public func write(_ settings: KDEProxy) throws {
        let old = try load()
        var config = old ?? KConfigFile(text: "")
        let wanted = [
            (Self.keys.type, settings.proxyType), (Self.keys.http, settings.httpProxy),
            (Self.keys.https, settings.httpsProxy),
        ]
        let changes = wanted.filter { config.value($0.0, in: Self.group) != $0.1 }
        let locked = changes.map(\.0).filter { isLocked($0, in: config) }
        guard locked.isEmpty else {
            throw GNOMEProxyStore.Locked(keys: locked.map { "kioslaverc [Proxy Settings] \($0)" })
        }
        for (key, value) in changes {
            if let value {
                config.setValue(value, for: key, in: Self.group)
            } else {
                config.removeValue(key, in: Self.group)
            }
        }
        // Reqly made the file, and nothing else is in it.
        let removesFile = !settings.fileExists && config.hasNoKeys
        if removesFile {
            guard old != nil else { return }
            try remove()
        } else {
            guard !changes.isEmpty else { return }
            try save(config)
        }
        if tellsApps {
            // Running apps reread the setting. Not all do, and a failure here leaves the file right.
            try? SessionBus.emit(
                path: "/KIO/Scheduler", interface: "org.kde.KIO.Scheduler", member: "reparseSlaveConfiguration",
                string: "")
        }
    }

    // MARK: - The file

    /// The file the name leads to, through a link, as kept in a folder of your settings files.
    private var target: URL { file.resolvingSymlinksInPath() }

    /// The file, or `nil` when it isn't there.
    private func load() throws -> KConfigFile? {
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        guard let data = try? Data(contentsOf: target) else {
            throw Failure(description: "Reqly couldn't read \(file.path).")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw Failure(description: "\(file.path) isn't UTF-8 text, so Reqly leaves it alone.")
        }
        return KConfigFile(text: text)
    }

    /// Whether KDE's system-wide files, or this one, lock `key`.
    private func isLocked(_ key: String, in config: KConfigFile) -> Bool {
        if config.isLocked(key, in: Self.group) {
            return true
        }
        return systemFiles.contains { file in
            guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else {
                return false
            }
            return KConfigFile(text: text).isLocked(key, in: Self.group)
        }
    }

    /// Writes `config` to a new file beside the old one, with the old one's permissions, or only
    /// yours for a new one, as KDE makes them, then renames it into place.
    private func save(_ config: KConfigFile) throws {
        let target = target
        let folder = target.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Failure(description: "Reqly couldn't make the folder for \(file.path).")
        }
        var status = stat()
        let mode = stat(target.path, &status) == 0 ? status.st_mode & 0o7777 : 0o600
        var template = Array(folder.appending(path: ".kioslaverc.reqly-XXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw Self.failure("couldn't write beside \(target.path)") }
        let temporary = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        var written = false
        defer {
            if !written {
                unlink(temporary)
            }
        }
        let bytes = Array(config.text.utf8)
        let complete = bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Glibc.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        let ok = complete && fchmod(fd, mode) == 0 && fsync(fd) == 0
        close(fd)
        guard ok else { throw Self.failure("couldn't write \(target.path)") }
        guard rename(temporary, target.path) == 0 else { throw Self.failure("couldn't replace \(target.path)") }
        written = true
    }

    private func remove() throws {
        guard unlink(target.path) == 0 || errno == ENOENT else { throw Self.failure("couldn't remove \(target.path)") }
    }

    private static func failure(_ what: String) -> Failure {
        Failure(description: "Reqly \(what): \(String(cString: strerror(errno))).")
    }
}
