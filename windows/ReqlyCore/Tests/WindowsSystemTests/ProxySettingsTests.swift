import Foundation
import ReqlyModel
import Testing
import WindowsSystem

@Suite struct ProxySettingsTests {
    /// Settings someone might have: a company proxy, its bypass list, and automatic detection.
    static let yours = ProxySettings(
        flags: ProxySettings.direct | ProxySettings.usesProxy | ProxySettings.detectsAutomatically,
        server: "proxy.corp:8080", bypass: "<local>;*.corp", setupScript: "http://wpad/old.pac")

    @Test func sendsHTTPAndHTTPSThroughReqlyAndKeepsTheRest() {
        let capturing = Self.yours.capturing(port: 9090)
        #expect(capturing.server == "http=127.0.0.1:9090;https=127.0.0.1:9090")
        #expect(capturing.flags == Self.yours.flags)
        #expect(capturing.bypass == "<local>;*.corp")
        #expect(capturing.setupScript == "http://wpad/old.pac")
        #expect(capturing.pointsAtReqly(port: 9090))
        #expect(!capturing.pointsAtReqly(port: 9091))
        #expect(!Self.yours.pointsAtReqly(port: 9090))
        // Direct only, as Windows starts: the proxy goes on.
        #expect(ProxySettings().capturing(port: 1).flags == ProxySettings.direct | ProxySettings.usesProxy)
        #expect(ProxySettings.noProxy == ProxySettings())
    }

    /// A restore file that Reqly for Windows' second beta left, as it wrote it, still puts your
    /// settings back after an update.
    @Test func putsBackWhatAnEarlierReqlyKept() throws {
        let folder = URL.temporaryDirectory.appending(path: "ReqlyProxyTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let restoreFile = folder.appending(path: "ProxyRestore.json")
        let kept = #"""
            {"yours":{"flags":11,"server":"proxy.corp:8080","bypass":"<local>;*.corp","setupScript":"http:\/\/wpad\/old.pac"},"port":9090}
            """#
        try FileReplacement.write(Data(kept.utf8), to: restoreFile)
        let settings = FileProxySettings<ProxySettings>(file: folder.appending(path: "Windows proxy settings.json"))
        try settings.write(Self.yours.capturing(port: 9090))

        #expect(try UserProxySwitch.restoreLeftBehind(settings: settings, restoreFile: restoreFile))
        #expect(try settings.read() == Self.yours)
        #expect(!FileManager.default.fileExists(atPath: restoreFile.path))
    }
}
