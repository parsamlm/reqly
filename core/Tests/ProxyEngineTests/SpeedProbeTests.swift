import Foundation
import Testing

/// How fast traffic goes through Reqly, next to going straight to the website: small requests one
/// at a time and 16 at a time, downloads, and HTTPS, decrypted and not. Each goes through the
/// engine in this process, which records nothing, and, with `REQLY_SPEED_APP=127.0.0.1:9091`,
/// through a Reqly that's running, which records it all. And how fast TLS itself is here, with
/// each cipher, since Reqly's decryption runs TLS twice. `SpeedProbe` holds the measurements.
///
/// It runs only when asked, in a release build:
/// `REQLY_SPEED=1 swift test -c release -Xswiftc -enable-testing --filter SpeedProbeTests`.
/// For the running Reqly to decrypt the probe's website, it has to trust the website's root:
/// `REQLY_SPEED_ROOT=<folder>` keeps the root there, `websitesRoot` writes it, and the app
/// is told to trust `<folder>/root.pem`; then `REQLY_SPEED_APP_DECRYPTS=1`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["REQLY_SPEED"] != nil), .timeLimit(.minutes(10)))
struct SpeedProbeTests {
    @Test func websitesRoot() throws {
        print("speed: the website's root is \(try SpeedProbe.websiteRoot().name)")
    }

    @Test func smallRequestsOneAtATime() async throws {
        print("speed: " + (try await SpeedProbe.smallRequestsOneAtATime()))
    }

    @Test func smallRequestsSixteenAtATime() async throws {
        print("speed: " + (try await SpeedProbe.smallRequestsSixteenAtATime()))
    }

    @Test func plainDownload() async throws {
        print("speed: " + (try await SpeedProbe.plainDownload()))
    }

    @Test func httpsOneAtATime() async throws {
        print("speed: " + (try await SpeedProbe.httpsOneAtATime()))
    }

    @Test func httpsDownload() async throws {
        print("speed: " + (try await SpeedProbe.httpsDownload()))
    }

    @Test func ciphers() async throws {
        print("speed: " + (try await SpeedProbe.ciphers()))
    }
}
