import CLinux
import Foundation

@testable import LinuxDesktop

/// What the tests need for the whole process, before GIO first looks: GSettings in memory, so
/// the tests never reach dconf, and a session bus of their own, which starts no services.
///
/// linux/scripts/app.sh sets both up before the tests start, with `REQLY_TEST_BUS`, so nothing
/// changes the environment while other tests' threads read it. A `swift test` run another way
/// gets them here, the first time a test asks.
enum TestEnvironment {
    /// The private session bus's address, or `nil` when there's no `dbus-daemon` to run one.
    static let sessionBus: String? = {
        let inherited = ProcessInfo.processInfo.environment
        if inherited["REQLY_TEST_BUS"] == "1", inherited["GSETTINGS_BACKEND"] == "memory",
            let address = inherited["DBUS_SESSION_BUS_ADDRESS"]
        {
            return address
        }
        setenv("GSETTINGS_BACKEND", "memory", 1)
        var output: [Int32] = [0, 0]
        guard pipe(&output) == 0 else { return nil }
        defer { close(output[0]) }
        // Started as Reqly starts programs, so it keeps none of the tests' descriptors but the
        // pipe it prints its address to. It forks, and the first process ends.
        let configuration = URL(filePath: #filePath).deletingLastPathComponent().appending(
            path: "../../scripts/test-bus.conf"
        ).standardizedFileURL.path
        let arguments = [
            "/usr/bin/dbus-daemon", "--config-file=\(configuration)", "--fork", "--nopidfile", "--print-address=1",
        ]
        let copies = arguments.map { strdup($0) } + [nil]
        let environment: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin"), nil]
        defer { (copies + environment).forEach { free($0) } }
        let daemon = reqly_spawn_detached(arguments[0], copies, environment, output[1])
        close(output[1])
        guard daemon > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 512)
        var poll = pollfd(fd: output[0], events: Int16(POLLIN), revents: 0)
        let count = Glibc.poll(&poll, 1, 5000) == 1 ? read(output[0], &buffer, buffer.count) : -1
        _ = Programs.wait(for: daemon, seconds: 5)
        guard count > 0 else { return nil }
        let address = String(decoding: buffer[..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        setenv("DBUS_SESSION_BUS_ADDRESS", address, 1)
        return address
    }()

    /// Sets it all up, the first time.
    static func prepare() {
        _ = sessionBus
    }

    /// A new, empty folder for one test.
    static func folder() throws -> URL {
        let folder = URL.temporaryDirectory.appending(path: "ReqlyDesktopTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
