import AppSetup
import Foundation
import Testing

@Suite struct AppFoldersTests {
    private let environment = [
        "HOME": "/home/ana", "XDG_CONFIG_HOME": "/c", "XDG_STATE_HOME": "/s", "XDG_DATA_HOME": "/d",
    ]

    @Test func keepsEachFileWhereThePlanSays() throws {
        let folders = AppFolders(options: try Options([]), environment: environment)
        #expect(folders.settingsFile.path == "/c/reqly/Settings.json")
        #expect(folders.rulesFile.path == "/c/reqly/Rules.json")
        #expect(folders.connectionsFile.path == "/c/reqly/Connections.json")
        #expect(folders.protobufFile.path == "/c/reqly/Protobuf.json")
        #expect(folders.devicesFile.path == "/c/reqly/Devices.json")
        #expect(folders.sessionsFolder.path == "/s/reqly/Sessions")
        #expect(folders.crashReportsFolder.path == "/s/reqly/Crashes")
        #expect(folders.proxyRestoreFile.path == "/s/reqly/ProxyRestore.json")
        #expect(folders.rootFile.path == "/d/reqly/Certificate.dat")
        #expect(folders.secretsFile.path == "/d/reqly/Secrets.json")
    }

    @Test func takesTheCommandLinesFiles() throws {
        let options = try Options([
            "--settings-file", "/t/Settings.json", "--rules-file", "/t/Rules.json",
            "--connections-file", "/t/Connections.json", "--protobuf-file", "/t/Protobuf.json",
            "--devices-file", "/t/Devices.json", "--sessions-folder", "/t/Sessions",
            "--crash-reports-folder", "/t/Crashes", "--proxy-restore-file", "/t/ProxyRestore.json",
            "--root-file", "/t/Certificate.dat", "--secrets-stand-in", "/t/Secrets.json",
        ])
        let folders = AppFolders(options: options, environment: environment)
        #expect(folders.settingsFile.path == "/t/Settings.json")
        #expect(folders.rulesFile.path == "/t/Rules.json")
        #expect(folders.connectionsFile.path == "/t/Connections.json")
        #expect(folders.protobufFile.path == "/t/Protobuf.json")
        #expect(folders.devicesFile.path == "/t/Devices.json")
        #expect(folders.sessionsFolder.path == "/t/Sessions")
        #expect(folders.crashReportsFolder.path == "/t/Crashes")
        #expect(folders.proxyRestoreFile.path == "/t/ProxyRestore.json")
        #expect(folders.rootFile.path == "/t/Certificate.dat")
        #expect(folders.secretsFile.path == "/t/Secrets.json")
    }

    @Test func opensTheLiveSessionWithTheStandIns() throws {
        let options = try Options([
            "--sessions-folder", "/t/Sessions", "--proxy-settings-stand-in", "/t/proxy.json",
            "--proxy-restore-file", "/t/ProxyRestore.json", "--root-stand-in", "/t/Root.dat",
        ])
        let open = AppFolders(options: options, environment: environment).openOptions(options)
        #expect(open.sessionsFolder == "/t/Sessions")
        #expect(open.file == nil)
        #expect(open.setsSystemProxy == true)
        #expect(open.proxyRestoreFile == "/t/ProxyRestore.json")
        #expect(open.proxySettingsStandIn == "/t/proxy.json")
        #expect(open.findsApps == true)
        #expect(open.rootStandIn == "/t/Root.dat")

        let real = try Options([])
        let realOpen = AppFolders(options: real, environment: environment).openOptions(real)
        #expect(realOpen.setsSystemProxy == true)
        #expect(realOpen.proxySettingsStandIn == nil)
        #expect(realOpen.rootStandIn == nil)
        #expect(realOpen.rootFile == "/d/reqly/Certificate.dat")
    }

    /// A test run never reaches the files the Reqly you use keeps, which runs beside it: not its
    /// restore file, and not your certificate store.
    @Test func keepsATestRunAwayFromYourRestoreFileAndCertificate() throws {
        let standIn = try Options(["--proxy-settings-stand-in", "/t/ProxySettings.json"])
        let folders = AppFolders(options: standIn, environment: environment)
        #expect(folders.proxyRestoreFile.path == "/t/ProxySettings-Restore.json")
        #expect(folders.openOptions(standIn).proxyRestoreFile == "/t/ProxySettings-Restore.json")

        for arguments in [
            ["--settings-file", "/t/Settings.json"], ["--app-id", "net.reqly.Test"], ["--smoke", "/t/report.txt"],
            ["--root-file", "/t/Certificate.dat", "--secrets-stand-in", "/t/Secrets.json"],
        ] {
            let testRun = try Options(arguments)
            #expect(!testRun.usesYourCertificates)
            #expect(AppFolders(options: testRun, environment: environment).openOptions(testRun).rootFile == nil)
        }
        #expect(try Options([]).usesYourCertificates)
        #expect(try Options(["--trust-helper", "/usr/local/libexec/reqly/reqly-trust"]).usesYourCertificates)
    }

    @Test func makesASessionsFolderOnlyYouCanOpen() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = folder.appending(path: "state")
        let sessions = state.appending(path: "reqly/Sessions")
        let folders = AppFolders(options: try Options([]), environment: ["XDG_STATE_HOME": state.path])
        #expect(folders.sessionsFolder.path == sessions.path)
        try folders.makeSessionsFolder()
        #expect(try mode(of: sessions) == 0o700)
        // One made before, which others could open, is made private too.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sessions.path)
        try folders.makeSessionsFolder()
        #expect(try mode(of: sessions) == 0o700)
    }

    /// A folder the command line names that's there already may be one of yours, such as
    /// Documents, so it keeps its permissions. One Reqly makes is private.
    @Test func leavesTheModeOfAFolderYouNameAlone() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let yours = folder.appending(path: "Documents")
        try FileManager.default.createDirectory(at: yours, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: yours.path)
        try AppFolders(options: try Options(["--sessions-folder", yours.path]), environment: environment)
            .makeSessionsFolder()
        #expect(try mode(of: yours) == 0o755)

        let made = folder.appending(path: "test/Sessions")
        try AppFolders(options: try Options(["--sessions-folder", made.path]), environment: environment)
            .makeSessionsFolder()
        #expect(try mode(of: made) == 0o700)
    }
}
