import AppSetup
import Foundation
import Testing

@testable import ReqlyApp

/// The self-check changes what it finds, so it runs only on stand-ins and a scratch home, as
/// linux/scripts/self-check.sh gives it.
@Suite struct SelfCheckRefusalTests {
    static let standIns = [
        "--proxy-settings-stand-in", "/s/ProxySettings.json", "--root-stand-in", "/s/Root.dat",
        "--secrets-stand-in", "/s/Secrets.json",
    ]
    static let scratchHome = [
        "HOME": "/s/home", "XDG_CONFIG_HOME": "/s/config", "XDG_DATA_HOME": "/s/data", "XDG_STATE_HOME": "/s/state",
    ]
    static let report = URL(filePath: "/s/report.txt")

    @Test func runsAsSelfCheckShRunsIt() throws {
        let options = try Options(["--smoke", Self.report.path] + Self.standIns)
        #expect(SelfCheck.refusal(options: options, report: Self.report, environment: Self.scratchHome) == nil)
        // The XDG folders follow the home when they aren't set.
        #expect(SelfCheck.refusal(options: options, report: Self.report, environment: ["HOME": "/s/home"]) == nil)
    }

    @Test func refusesWithoutTheStandIns() throws {
        let options = try Options(["--smoke", Self.report.path, "--proxy-settings-stand-in", "/s/ProxySettings.json"])
        let refusal = SelfCheck.refusal(options: options, report: Self.report, environment: Self.scratchHome)
        #expect(
            refusal
                == "The self-check needs --root-stand-in, --secrets-stand-in, so it changes nothing of yours. Run it "
                + "with linux/scripts/self-check.sh.")
    }

    @Test func refusesYourOwnHomeAndFolders() throws {
        let options = try Options(["--smoke", Self.report.path] + Self.standIns)
        var yours = Self.scratchHome
        yours["HOME"] = "/home/ana"
        yours["XDG_DATA_HOME"] = "/home/ana/.local/share"
        let refusal = SelfCheck.refusal(options: options, report: Self.report, environment: yours)
        #expect(
            refusal?.hasPrefix("The self-check runs only with HOME, XDG_DATA_HOME in the report's folder, /s/") == true)
        // A folder whose name only starts the same isn't inside.
        yours = Self.scratchHome
        yours["XDG_CONFIG_HOME"] = "/s2/config"
        #expect(SelfCheck.refusal(options: options, report: Self.report, environment: yours) != nil)
    }
}
