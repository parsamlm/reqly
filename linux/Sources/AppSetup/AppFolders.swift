import CoreInterface
import Foundation
import LinuxSystem

/// Where this run keeps each of its files: where the command line puts them, or else as the XDG
/// base directories say, through ``LinuxFolders``. Your settings and the other files Windows keeps
/// beside them go in `~/.config/reqly`, live sessions in `~/.local/state/reqly/Sessions`, and the
/// certificate and the secrets in `~/.local/share/reqly` when there's no keyring for them.
public struct AppFolders: Sendable {
    /// Your settings for Reqly, ``AppSettings``.
    public var settingsFile: URL
    /// The rules, in the JSON the Mac and Windows keep them in.
    public var rulesFile: URL
    /// The upstream proxy, the reverse proxies and the client certificates.
    public var connectionsFile: URL
    /// The `.proto` files bodies are read with, and the message types chosen.
    public var protobufFile: URL
    /// The devices you let in, and the names you gave them.
    public var devicesFile: URL
    /// Each live session's folder, which can grow to gigabytes and goes when Reqly quits.
    public var sessionsFolder: URL
    public var crashReportsFolder: URL
    /// Your proxy settings while Reqly captures, so they come back if it quits unexpectedly.
    public var proxyRestoreFile: URL
    /// Reqly's certificate, and its key when there's no keyring.
    public var rootFile: URL
    /// The secrets, when there's no keyring for them, or a test run's plain file.
    public var secretsFile: URL

    /// The files for a run with `options`, in the folders `environment` names, such as the
    /// process's own.
    public init(options: Options, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let linux = LinuxFolders(environment: environment)
        func file(_ option: String?, _ fallback: URL) -> URL {
            option.map { URL(filePath: $0) } ?? fallback
        }
        func folder(_ option: String?, _ fallback: URL) -> URL {
            option.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? fallback
        }
        settingsFile = file(options.settingsFile, linux.config.appending(path: "Settings.json"))
        rulesFile = file(options.rulesFile, linux.config.appending(path: "Rules.json"))
        connectionsFile = file(options.connectionsFile, linux.config.appending(path: "Connections.json"))
        protobufFile = file(options.protobufFile, linux.config.appending(path: "Protobuf.json"))
        devicesFile = file(options.devicesFile, linux.config.appending(path: "Devices.json"))
        sessionsFolder = folder(
            options.sessionsFolder, linux.state.appending(path: "Sessions", directoryHint: .isDirectory))
        crashReportsFolder = folder(
            options.crashReportsFolder, linux.state.appending(path: "Crashes", directoryHint: .isDirectory))
        proxyRestoreFile = file(options.proxyRestoreFile, linux.proxyRestoreFile)
        rootFile = file(options.rootFile, linux.rootFile)
        secretsFile = file(options.secretsStandIn, linux.secretsFile)
    }

    /// Makes the sessions folder if it's missing, and lets only you open it: sessions hold
    /// whatever your apps sent, passwords and cookies included.
    public func makeSessionsFolder() throws {
        try FileManager.default.createDirectory(at: sessionsFolder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessionsFolder.path)
    }

    /// What the live session opens with: these files, and the stand-ins `options` names. It finds
    /// which app sent each request.
    public func openOptions(_ options: Options) -> OpenOptions {
        OpenOptions(
            sessionsFolder: sessionsFolder.path, setsSystemProxy: options.setsSystemProxy,
            proxyRestoreFile: proxyRestoreFile.path, proxySettingsStandIn: options.proxySettingsStandIn,
            findsApps: true, rootFile: rootFile.path, rootStandIn: options.rootStandIn)
    }
}
