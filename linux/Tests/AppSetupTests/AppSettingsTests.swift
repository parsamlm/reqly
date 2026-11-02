import AppSetup
import Foundation
import ReqlyModel
import Testing

@Suite struct AppSettingsTests {
    @Test func startsAsTheMacAndWindowsDo() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = AppSettings.load(from: folder.appending(path: "Settings.json"))
        #expect(settings == AppSettings())
        #expect(settings.proxyPort == 9090)
        #expect(!settings.startsCapturingOnLaunch)
        #expect(settings.decryptedHosts == DecryptedHosts())
    }

    @Test func readsTheWindowsAppsFile() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Settings.json")
        try Data(
            """
            {
              "proxyPort": 9191,
              "startsCapturingOnLaunch": true,
              "decryptedHosts": {
                "entries": [{"pattern": "api.example.com", "isOn": true}, {"pattern": "*.test", "isOn": false}],
                "includesEveryHost": false
              },
              "sidebarIsOpen": true,
              "showsNotificationIcon": false
            }
            """.utf8
        ).write(to: file)
        let settings = AppSettings.load(from: file)
        #expect(settings.proxyPort == 9191)
        #expect(settings.startsCapturingOnLaunch)
        #expect(settings.decryptedHosts.entries.map(\.pattern.rawValue) == ["api.example.com", "*.test"])
        #expect(settings.decryptedHosts.entries.map(\.isOn) == [true, false])
    }

    /// Each setting on its own: one that's missing or wrong keeps its first value, and the
    /// others still count.
    @Test func readsLeniently() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Settings.json")
        try Data(#"{"proxyPort": "9191", "startsCapturingOnLaunch": true, "decryptedHosts": 3}"#.utf8).write(to: file)
        var settings = AppSettings.load(from: file)
        #expect(settings.proxyPort == 9090)
        #expect(settings.startsCapturingOnLaunch)
        #expect(settings.decryptedHosts == DecryptedHosts())

        try Data(#"{"proxyPort": 0}"#.utf8).write(to: file)
        #expect(AppSettings.load(from: file).proxyPort == 9090)
        try Data("not JSON".utf8).write(to: file)
        settings = AppSettings.load(from: file)
        #expect(settings == AppSettings())
    }

    @Test func savesAFileOnlyYouCanRead() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "reqly/Settings.json")
        var settings = AppSettings()
        settings.proxyPort = 9292
        settings.decryptedHosts.decrypt("api.example.com")
        try settings.save(to: file)
        #expect(AppSettings.load(from: file) == settings)
        #expect(try mode(of: file) == 0o600)
        #expect(try mode(of: file.deletingLastPathComponent()) == 0o700)

        // Saved again over the first, with nothing left beside it.
        settings.startsCapturingOnLaunch = true
        try settings.save(to: file)
        #expect(AppSettings.load(from: file) == settings)
        let left = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(left == ["Settings.json"])
    }
}

/// A file's or folder's permissions, such as 0o600.
func mode(of url: URL) throws -> Int? {
    try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
}

/// A new empty folder for a test, which the test deletes.
func scratchFolder() throws -> URL {
    let folder = URL(filePath: NSTemporaryDirectory()).appending(path: "reqly-app-setup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}
