import Darwin
import Foundation
import HelperProtocol

/// What the helper saves before it changes anything, so it can always put the settings back.
public struct SavedState {
    public var port: Int
    /// The Reqly process that asked for the change. Its path guards against a reused process ID.
    public var appPID: Int32
    public var appPath: String
    /// Each network service's proxy settings from before the capture, by service ID.
    public var originals: [String: [String: Any]]

    public init(port: Int, appPID: Int32, appPath: String, originals: [String: [String: Any]]) {
        self.port = port
        self.appPID = appPID
        self.appPath = appPath
        self.originals = originals
    }

    init?(propertyList: [String: Any]) {
        guard let port = propertyList["port"] as? Int,
            let appPID = propertyList["appPID"] as? Int32,
            let appPath = propertyList["appPath"] as? String,
            let originals = propertyList["originals"] as? [String: [String: Any]]
        else { return nil }
        self.init(port: port, appPID: appPID, appPath: appPath, originals: originals)
    }

    var propertyList: [String: Any] {
        ["port": port, "appPID": appPID, "appPath": appPath, "originals": originals]
    }
}

/// The file that holds the saved state. It lives in a folder only root can open.
public struct StateFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `/Library/Application Support/<helper identifier>/saved-proxy-settings.plist`
    public static func standard(helperIdentifier: String) -> StateFile {
        StateFile(url: URL(filePath: "/Library/Application Support/\(helperIdentifier)/saved-proxy-settings.plist"))
    }

    public func load() throws -> SavedState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let list = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let state = SavedState(propertyList: list)
        else { throw HelperError.cannotReadSettings }
        return state
    }

    public func save(_ state: SavedState) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try PropertyListSerialization.data(fromPropertyList: state.propertyList, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// Finds out whether a process still runs, and what program it is.
public protocol ProcessLookup: Sendable {
    /// The program a running process was started from, or `nil` if the process is gone.
    func executablePath(of pid: Int32) -> String?
}

public struct SystemProcessLookup: ProcessLookup {
    public init() {}

    public func executablePath(of pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }
}
