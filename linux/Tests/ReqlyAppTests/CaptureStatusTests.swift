import LinuxDesktop
import Testing

@testable import ReqlyApp

@Suite struct CaptureStatusTests {
    static func status(
        _ capture: AppModel.Capture, proxySet: ProxyParts = [], chrome: ChromeProxySetting = .gnome,
        terminals: [String] = [], openedTerminals: Bool = false, problem: String? = nil
    ) -> String {
        CaptureStatus(
            capture: capture, port: 9090, problem: problem, proxySet: proxySet, chrome: chrome,
            terminalsKeepingProxy: terminals, openedTerminalsKeepProxy: openedTerminals
        ).text
    }

    @Test func saysWhichDesktopsProxyPointsAtReqly() {
        #expect(
            Self.status(.capturing, proxySet: .gnome)
                == "Capturing on port 9090 · Proxy set for GNOME · Apps keep connections they already had open, "
                + "so restart Firefox to capture all of its traffic")
        #expect(
            Self.status(.capturing, proxySet: [.gnome, .kde], chrome: .kde)
                == "Capturing on port 9090 · Proxy set for GNOME and KDE · Apps keep connections they already had "
                + "open, so restart Firefox to capture all of its traffic")
    }

    @Test func asksForARestartWhereChromeDoesntReadTheSetting() {
        let restart =
            "Capturing on port 9090 · Proxy set for GNOME · Restart apps you opened earlier, or start "
            + "them from Open Terminal"
        #expect(Self.status(.capturing, proxySet: .gnome, chrome: .none) == restart)
        // On KDE, Chrome reads KDE's setting, so GNOME's alone isn't enough.
        #expect(Self.status(.capturing, proxySet: .gnome, chrome: .kde) == restart)
    }

    @Test func saysWhenTheDesktopsProxyIsLeftAlone() {
        #expect(Self.status(.capturing) == "Capturing on port 9090 · Desktop proxy not set")
    }

    @Test func namesTheTerminalsThatKeepTheProxyOnceCapturingStops() {
        #expect(Self.status(.stopped) == "Not capturing · Port 9090")
        // A new tab copies the variables of the tab it's opened from, so a new window it is.
        #expect(
            Self.status(.stopped, terminals: ["GNOME Terminal"])
                == "Not capturing · Port 9090 · GNOME Terminal tabs opened while capturing still point at Reqly, "
                + "so open a new window")
        #expect(
            Self.status(.stopped, terminals: ["GNOME Terminal", "Ptyxis"])
                == "Not capturing · Port 9090 · GNOME Terminal and Ptyxis tabs opened while capturing still point "
                + "at Reqly, so open a new window")
        // The terminals Open Terminal opened keep the variables too, as Konsole's do on KDE.
        #expect(
            Self.status(.stopped, openedTerminals: true)
                == "Not capturing · Port 9090 · The terminals Reqly opened still point at Reqly, so open a new window")
        #expect(
            Self.status(.stopped, terminals: ["GNOME Terminal"], openedTerminals: true)
                == "Not capturing · Port 9090 · GNOME Terminal tabs opened while capturing, and the terminals Reqly "
                + "opened, still point at Reqly, so open a new window")
        #expect(CaptureStatus.terminalsFollowingGNOME.map(\.name) == ["GNOME Terminal", "Ptyxis", "GNOME Console"])
    }

    @Test func showsTheSessionsProblemAndTheStepsBetween() {
        let problem = "Reqly couldn't start capturing. Another app already uses port 9090."
        #expect(Self.status(.stopped, terminals: ["Ptyxis"], problem: problem) == problem)
        #expect(Self.status(.starting) == "Starting…")
        #expect(Self.status(.stopping) == "Stopping…")
    }

    @Test func readsWhoseSettingChromeFollowsAsChromeDoes() {
        #expect(ChromeProxySetting(currentDesktop: "ubuntu:GNOME") == .gnome)
        #expect(ChromeProxySetting(currentDesktop: "GNOME") == .gnome)
        #expect(ChromeProxySetting(currentDesktop: "X-Cinnamon") == .gnome)
        #expect(ChromeProxySetting(currentDesktop: "Budgie:GNOME") == .gnome)
        #expect(ChromeProxySetting(currentDesktop: "MATE") == .gnome)
        #expect(ChromeProxySetting(currentDesktop: "KDE") == .kde)
        #expect(ChromeProxySetting(currentDesktop: "XFCE") == .none)
        #expect(ChromeProxySetting(currentDesktop: "LXQt") == .none)
        #expect(ChromeProxySetting(currentDesktop: "labwc:wlroots") == .none)
        #expect(ChromeProxySetting(currentDesktop: nil) == .none)
        // The first name Chrome knows decides.
        #expect(ChromeProxySetting(currentDesktop: "XFCE:GNOME") == .none)
    }

    @Test func findsThePartsThatPointAtReqly() {
        let yours = DesktopProxySettings(gnome: GNOMEProxy(), kde: KDEProxy(fileExists: true))
        #expect(ProxyParts(yours) == [.gnome, .kde])
        #expect(ProxyParts(DesktopProxySettings.noProxy) == .gnome)
        #expect(ProxyParts(yours, pointingAtReqlyOn: 9090) == [])
        let capturing = yours.capturing(port: 9090)
        #expect(ProxyParts(capturing, pointingAtReqlyOn: 9090) == [.gnome, .kde])
        #expect(ProxyParts(capturing, pointingAtReqlyOn: 9191) == [])
        var gnomeOnly = capturing
        gnomeOnly.kde = yours.kde
        #expect(ProxyParts(gnomeOnly, pointingAtReqlyOn: 9090) == .gnome)
        #expect(ProxyParts([.gnome, .kde]).settings == "GNOME's and KDE's proxy settings")
        #expect(ProxyParts.kde.settings == "KDE's proxy setting")
        #expect(ProxyParts().settings == nil)
    }
}
