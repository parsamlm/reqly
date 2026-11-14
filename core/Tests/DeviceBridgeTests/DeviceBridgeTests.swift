import Foundation
import Testing

@testable import DeviceBridge

#if os(Windows)
    import WinSDK
#endif

@Suite struct DeviceBridgeTests {
    @Test func readsTheAndroidDevices() {
        let output = """
            * daemon not running; starting now at tcp:5037
            * daemon started successfully
            List of devices attached
            emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
            R5CT1234567            unauthorized usb:1-1 transport_id:2

            """
        let devices = AndroidDebugBridge.parseDevices(output)
        #expect(
            devices == [
                AndroidDevice(id: "emulator-5554", state: "device", model: "sdk_gphone64_arm64"),
                AndroidDevice(id: "R5CT1234567", state: "unauthorized"),
            ])
        #expect(devices.map(\.isEmulator) == [true, false])
        #expect(AndroidDebugBridge.proxySetting("10.0.2.2:9090\r\n") == "10.0.2.2:9090")
        #expect(AndroidDebugBridge.proxySetting(":0\n") == nil)
        #expect(AndroidDebugBridge.proxySetting("null\n") == nil)
    }

    #if os(macOS)
        @Test func findsAdbWhereTheSDKPutsIt() throws {
            let home = URL.temporaryDirectory.appending(path: "ReqlyTests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: home) }
            #expect(
                AndroidDebugBridge.find(environment: [:], home: home)?.executable.path(percentEncoded: false).hasPrefix(
                    home.path(percentEncoded: false)) != true)
            let tools = home.appending(path: "Library/Android/sdk/platform-tools")
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            let adb = tools.appending(path: "adb")
            try Data("#!/bin/sh\n".utf8).write(to: adb)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: adb.path(percentEncoded: false))
            #expect(AndroidDebugBridge.find(environment: [:], home: home)?.executable == adb)
        }
    #endif

    #if os(Linux)
        @Test func findsAdbWhereAndroidStudioAndDebianPutIt() throws {
            let folder = URL.temporaryDirectory.appending(path: "ReqlyTests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let home = folder.appending(path: "home")
            // Stand-ins for /usr/bin, /usr/lib/android-sdk/platform-tools and /usr/local/bin.
            let system = ["usr/bin", "usr/lib/android-sdk/platform-tools", "usr/local/bin"].map {
                folder.appending(path: $0)
            }
            func find(_ environment: [String: String] = [:]) -> String? {
                AndroidDebugBridge.find(environment: environment, home: home, systemFolders: system)?.executable
                    .path(percentEncoded: false)
            }
            #expect(find() == nil)
            #expect(
                AndroidDebugBridge.systemFolders.map { $0.path(percentEncoded: false) } == [
                    "/usr/bin", "/usr/lib/android-sdk/platform-tools", "/usr/local/bin",
                ])
            // Debian's package puts adb beside the SDK's other tools, and a link to it in /usr/bin.
            let packaged = try Self.makeAdb(in: system[1])
            #expect(find() == packaged)
            let linked = try Self.makeAdb(in: system[0])
            #expect(find() == linked)
            // Android Studio's comes before them, and the SDK that ANDROID_HOME names before that.
            let studio = try Self.makeAdb(in: home.appending(path: "Android/Sdk/platform-tools"))
            #expect(find() == studio)
            let sdk = folder.appending(path: "sdk")
            let named = try Self.makeAdb(in: sdk.appending(path: "platform-tools"))
            #expect(find(["ANDROID_HOME": sdk.path(percentEncoded: false)]) == named)
        }

        @Test func findsAdbInPathLast() throws {
            let folder = URL.temporaryDirectory.appending(path: "ReqlyTests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let home = folder.appending(path: "home")
            let system = [folder.appending(path: "usr/bin")]
            let first = folder.appending(path: "first")
            let second = folder.appending(path: "second")
            let path = "relative:\(first.path(percentEncoded: false)):\(second.path(percentEncoded: false))"
            func find() -> String? {
                AndroidDebugBridge.find(environment: ["PATH": path], home: home, systemFolders: system)?.executable
                    .path(percentEncoded: false)
            }
            // Only a file you can run counts.
            _ = try Self.makeAdb(in: first, canRun: false)
            #expect(find() == nil)
            let inPath = try Self.makeAdb(in: second)
            #expect(find() == inPath)
            let inSystem = try Self.makeAdb(in: system[0])
            #expect(find() == inSystem)
        }

        /// Writes a stand-in adb in `folder`, made if it's missing, and gives its path.
        static func makeAdb(in folder: URL, canRun: Bool = true) throws -> String {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let adb = folder.appending(path: "adb")
            try Data("#!/bin/sh\n".utf8).write(to: adb)
            try FileManager.default.setAttributes(
                [.posixPermissions: canRun ? 0o755 : 0o644], ofItemAtPath: adb.path(percentEncoded: false))
            return adb.path(percentEncoded: false)
        }
    #endif

    #if os(Windows)
        @Test func runsATool() async throws {
            let shell = URL(filePath: "C:/Windows/System32/cmd.exe")
            let echoed = try await Tool.run(shell, ["/c", "echo hello"])
            #expect(echoed.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
            await #expect(throws: Tool.Failure.self) {
                try await Tool.run(shell, ["/c", "exit 3"])
            }
            // A tool that takes too long is stopped. It only waits, pinging this PC.
            let start = ContinuousClock.now
            await #expect(throws: Tool.Failure.self) {
                try await Tool.run(
                    URL(filePath: "C:/Windows/System32/PING.EXE"), ["-n", "10", "127.0.0.1"],
                    timeout: .milliseconds(500))
            }
            #expect(ContinuousClock.now - start < .seconds(5))
        }

        @Test func aToolGetsNoneOfReqlysSockets() async throws {
            // A listening socket, as Reqly's proxy has. Windows lets new processes inherit a socket
            // unless it's told otherwise.
            var data = WSADATA()
            try #require(WSAStartup(0x0202, &data) == 0)
            defer { WSACleanup() }
            let listening = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
            let port = try Self.listen(listening, port: 0)
            // A tool that runs for a few seconds, started while the socket is open.
            let ping = URL(filePath: "C:/Windows/System32/PING.EXE")
            let tool = Task { try? await Tool.run(ping, ["-n", "4", "127.0.0.1"]) }
            try await Task.sleep(for: .milliseconds(500))
            closesocket(listening)
            // The port is free again at once, since the tool never got the socket.
            let again = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
            defer { closesocket(again) }
            var exclusive: Int32 = 1
            _ = withUnsafeBytes(of: &exclusive) { value in
                let bytes = value.baseAddress?.assumingMemoryBound(to: CChar.self)
                // SO_EXCLUSIVEADDRUSE, a macro Swift doesn't bring in, as Reqly's proxy listens.
                return setsockopt(again, SOL_SOCKET, ~SO_REUSEADDR, bytes, Int32(value.count))
            }
            #expect((try? Self.listen(again, port: port)) == port)
            _ = await tool.value
        }

        @Test func quotesArgumentsAsWindowsProgramsReadThem() {
            #expect(WindowsTool.quoted("Pixel_9") == "Pixel_9")
            #expect(WindowsTool.quoted("") == #""""#)
            #expect(WindowsTool.quoted(#"C:\Users\Parsa M\Reqly CA.pem"#) == #""C:\Users\Parsa M\Reqly CA.pem""#)
            #expect(WindowsTool.quoted(#"say "hi""#) == #""say \"hi\"""#)
            #expect(WindowsTool.quoted(#"C:\with space\"#) == #""C:\with space\\""#)
        }

        /// Listens on `port` on this PC's loopback address, or on a free one for 0, and says which.
        static func listen(_ socket: SOCKET, port: Int) throws -> Int {
            struct Failed: Error {
                var code: Int32
            }
            var address = sockaddr_in()
            address.sin_family = ADDRESS_FAMILY(AF_INET)
            address.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian
            address.sin_port = UInt16(port).bigEndian
            var length = Int32(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    bind(socket, address, length) == 0 && WinSDK.listen(socket, 1) == 0
                        && getsockname(socket, address, &length) == 0
                }
            }
            guard bound else { throw Failed(code: WSAGetLastError()) }
            return Int(UInt16(bigEndian: address.sin_port))
        }
    #else
        @Test func runsATool() async throws {
            let echoed = try await Tool.run(URL(filePath: "/bin/echo"), ["hello"])
            #expect(echoed == "hello\n")
            await #expect(throws: Tool.Failure.self) {
                try await Tool.run(URL(filePath: "/bin/sh"), ["-c", "echo nope >&2; exit 3"])
            }
            // A tool that takes too long is stopped.
            let start = ContinuousClock.now
            await #expect(throws: Tool.Failure.self) {
                try await Tool.run(URL(filePath: "/bin/sleep"), ["10"], timeout: .milliseconds(200))
            }
            #expect(ContinuousClock.now - start < .seconds(5))
        }
    #endif

    @Test func writesCertificatesAsPEM() {
        let pem = Data([0x30, 0x82, 0x01, 0x0A]).pemCertificate
        #expect(pem == "-----BEGIN CERTIFICATE-----\nMIIBCg==\n-----END CERTIFICATE-----\n")
    }
}
