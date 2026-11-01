import AppSetup
import Testing

@Suite struct OptionsTests {
    @Test func readsTheWindowsAppsNames() throws {
        let options = try Options([
            "--port", "9191", "--starts-capturing", "yes", "--sets-system-proxy", "no",
            "--proxy-settings-stand-in", "/t/proxy.json", "--proxy-restore-file", "/t/restore.json",
            "--settings-file", "/t/Settings.json", "--rules-file", "/t/Rules.json",
            "--connections-file", "/t/Connections.json", "--protobuf-file", "/t/Protobuf.json",
            "--devices-file", "/t/Devices.json", "--sessions-folder", "/t/Sessions",
            "--crash-reports-folder", "/t/Crashes", "--log-file", "/t/reqly.log",
            "--secrets-stand-in", "/t/Secrets.json", "--root-file", "/t/Certificate.dat",
            "--root-stand-in", "/t/Root.dat", "--trust-helper", "/t/reqly-trust",
            "--allows-network-devices", "no", "--checks-for-updates", "no", "--has-seen-welcome", "yes",
            "--theme", "dark", "--smoke", "/t/report.txt", "--smoke-parts", "window,events",
        ])
        #expect(options.command == .open)
        #expect(options.port == 9191)
        #expect(options.startsCapturing == true)
        #expect(options.setsSystemProxy == false)
        #expect(options.proxySettingsStandIn == "/t/proxy.json")
        #expect(options.proxyRestoreFile == "/t/restore.json")
        #expect(options.settingsFile == "/t/Settings.json")
        #expect(options.rulesFile == "/t/Rules.json")
        #expect(options.connectionsFile == "/t/Connections.json")
        #expect(options.protobufFile == "/t/Protobuf.json")
        #expect(options.devicesFile == "/t/Devices.json")
        #expect(options.sessionsFolder == "/t/Sessions")
        #expect(options.crashReportsFolder == "/t/Crashes")
        #expect(options.logFile == "/t/reqly.log")
        #expect(options.secretsStandIn == "/t/Secrets.json")
        #expect(options.rootFile == "/t/Certificate.dat")
        #expect(options.rootStandIn == "/t/Root.dat")
        #expect(options.trustHelper == "/t/reqly-trust")
        #expect(options.allowsNetworkDevices == false)
        #expect(options.checksForUpdates == false)
        #expect(options.hasSeenWelcome == true)
        #expect(options.theme == .dark)
        #expect(options.smokeReport == "/t/report.txt")
        #expect(options.smokeParts == ["window", "events"])
        #expect(options.isTestRun)
    }

    @Test func knowsItsCommands() throws {
        #expect(try Options([]).command == .open)
        #expect(try Options(["--help"]).command == .help)
        #expect(try Options(["-h"]).command == .help)
        #expect(try Options(["--version"]).command == .version)
        let removal = try Options(["--remove-certificate", "--root-stand-in", "/t/Root.dat"])
        #expect(removal.command == .removeCertificate)
        #expect(removal.rootStandIn == "/t/Root.dat")
    }

    /// Desktops pass files even though the desktop file's Exec takes none, as Open With does: the
    /// run takes them, and opens Reqly's window, or brings back the one that's open.
    @Test func takesTheFilesADesktopPasses() throws {
        let options = try Options(["/home/ana/Documents/note.txt", "file:///etc/hostname"])
        #expect(options.command == .open)
        #expect(options.files == ["/home/ana/Documents/note.txt", "file:///etc/hostname"])
        #expect(!options.isTestRun)
        let mixed = try Options(["--port", "9191", "session.reqly"])
        #expect(mixed.port == 9191 && mixed.files == ["session.reqly"])
        #expect(try Options([]).files.isEmpty)
    }

    @Test func refusesWhatItCantFollow() {
        #expect(throws: Options.UsageError.self) { try Options(["--no-such-option", "1"]) }
        #expect(throws: Options.UsageError.self) { try Options(["-x"]) }
        #expect(throws: Options.UsageError.self) { try Options(["--settings-file"]) }
        #expect(throws: Options.UsageError.self) { try Options(["--port", "nine"]) }
        #expect(throws: Options.UsageError.self) { try Options(["--port", "70000"]) }
        #expect(throws: Options.UsageError.self) { try Options(["--sets-system-proxy", "maybe"]) }
        #expect(throws: Options.UsageError.self) { try Options(["--theme", "blue"]) }
        #expect(throws: Options.UsageError.self) { try Options(["--smoke-parts", ","]) }
        #expect(throws: Options.UsageError("--port takes a number from 0 to 65535, not -1.")) {
            try Options(["--port", "-1"])
        }
        // pkexec would look a bare name up in PATH.
        #expect(
            throws: Options.UsageError("--trust-helper takes the helper's full path, starting with /, not reqly-trust.")
        ) {
            try Options(["--trust-helper", "reqly-trust"])
        }
        #expect(throws: Options.UsageError.self) { try Options(["--trust-helper", "packaging/reqly-trust"]) }
    }

    /// A real run sets your desktop's proxy; a test run sets only a stand-in's, unless it's told
    /// otherwise.
    @Test func setsTheDesktopsProxyOnlyForARealRun() throws {
        let real = try Options(["--port", "9191"])
        #expect(!real.isTestRun)
        #expect(real.setsSystemProxy)
        #expect(try !Options(["--sets-system-proxy", "no"]).setsSystemProxy)

        for testRun in [
            ["--settings-file", "/t/Settings.json"], ["--root-stand-in", "/t/Root.dat"],
            ["--secrets-stand-in", "/t/Secrets.json"], ["--smoke", "/t/report.txt"],
        ] {
            let options = try Options(testRun)
            #expect(options.isTestRun)
            #expect(!options.setsSystemProxy)
        }
        let standIn = try Options(["--proxy-settings-stand-in", "/t/proxy.json"])
        #expect(standIn.isTestRun)
        #expect(standIn.setsSystemProxy)
        #expect(try Options(["--settings-file", "/t/Settings.json", "--sets-system-proxy", "yes"]).setsSystemProxy)
    }

    @Test func takesTheLastOfAnOptionGivenTwice() throws {
        let options = try Options(["--port", "9191", "--sets-system-proxy", "yes", "--port", "9292"])
        #expect(options.port == 9292)
        #expect(try Options(["--sets-system-proxy", "yes", "--sets-system-proxy", "no"]).setsSystemProxy == false)
    }
}
