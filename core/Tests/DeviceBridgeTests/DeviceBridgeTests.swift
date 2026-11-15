import Foundation
import Testing

@testable import DeviceBridge

#if os(Windows)
    import WinSDK
#elseif canImport(Glibc)
    import Glibc
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
            // A tool that takes too long is stopped, long before it would have ended. The limit
            // leaves room for CI, where tests that keep Swift's few threads busy can hold up the
            // deadline that stops the tool, and this test, for many seconds.
            let start = ContinuousClock.now
            await #expect(throws: Tool.Failure.self) {
                try await Tool.run(URL(filePath: "/bin/sleep"), ["120"], timeout: .milliseconds(200))
            }
            #expect(ContinuousClock.now - start < .seconds(60))
        }
    #endif

    #if os(Linux)
        /// adb starts its server and leaves it running, with whatever adb got from Reqly. A tool's
        /// call ends with the tool all the same, with what it printed, and what it leaves running
        /// has none of Reqly's descriptors and no signal blocked.
        @Test func endsWithTheToolThoughWhatItLeftKeepsItsPipes() async throws {
            // Reqly ignores SIGPIPE, which a tool shouldn't.
            signal(SIGPIPE, SIG_IGN)
            // Its output and errors stay open in the child for 30 seconds. The shell reads its
            // own signals with its builtins, since it blocks them all for a moment as it starts a
            // program.
            let printed = try await Self.runLeavingAChild(
                #"echo printed; echo complained >&2; sleep 30 & echo $! > "$1/child"; "#
                    + #"while read -r name value; do case $name in SigBlk:|SigIgn:) "#
                    + #"printf '%s\t%s\n' "$name" "$value";; esac; done < /proc/$$/status"#)
            let lines = printed.split(separator: "\n")
            #expect(lines.first == "printed" && lines.count == 3)
            #expect(lines.dropFirst().first == "SigBlk:\t0000000000000000")
            // Signals 1 to 31 aren't ignored. glibc's posix_spawn ignores its own two, 32 and 33, in
            // every program it starts.
            let ignored = lines.last.flatMap { UInt64($0.dropFirst("SigIgn:\t".count), radix: 16) }
            #expect(ignored.map { $0 & 0x7FFF_FFFF } == 0, "\(printed)")
            // A tool that fails says why, from its errors.
            do {
                _ = try await Self.runLeavingAChild(#"echo nope >&2; sleep 30 & echo $! > "$1/child"; exit 3"#)
                Issue.record("The tool's failure wasn't thrown")
            } catch let failure as Tool.Failure {
                #expect(failure.tool == "sh" && failure.message == "nope")
            }
        }

        @Test func aToolGetsNoneOfReqlysDescriptors() async throws {
            // The tool has only its input, output and errors, though this process has a socket
            // open that its programs could inherit. The child it leaves holds a descriptor above 2,
            // a file the tool opened, and none of the tool's pipes.
            let printed = try await Self.runLeavingAChild(
                #"ls /proc/$$/fd; exec 5> "$1/held"; sleep 30 < /dev/null > /dev/null 2>&1 & "#
                    + #"echo $! > "$1/child""#)
            #expect(printed == "0\n1\n2\n")
        }

        @Test func readsALotFromBothPipes() async throws {
            // More than a pipe holds, on each, so both are read as they fill.
            let printed = try await Tool.run(
                URL(filePath: "/bin/sh"), ["-c", "head -c 300000 /dev/zero | tr '\\0' a; head -c 300000 /dev/zero >&2"])
            #expect(printed.count == 300_000 && printed.allSatisfy { $0 == "a" })
            do {
                _ = try await Tool.run(URL(filePath: "/nonexistent/adb"), [])
                Issue.record("A tool that isn't there ran")
            } catch let failure as Tool.Failure {
                #expect(failure.message == "Linux couldn't start adb (No such file or directory).")
            }
        }

        /// Each tool waits on threads of its own, so tools that run for a while never hold up
        /// Swift's tasks, which share as many threads as the computer has cores.
        @Test func waitsOffSwiftsThreads() async throws {
            let count = max(ProcessInfo.processInfo.activeProcessorCount, 4) * 3
            let start = ContinuousClock.now
            let printed = try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0..<count {
                    group.addTask { try await Tool.run(URL(filePath: "/bin/sh"), ["-c", "sleep 1; echo done"]) }
                }
                return try await group.reduce(into: [String]()) { $0.append($1) }
            }
            #expect(printed == Array(repeating: "done\n", count: count))
            #expect(ContinuousClock.now - start < .seconds(2.5))
        }

        /// Runs `script` in a shell through Tool while a listening socket is open, as Reqly's
        /// proxy's is, and gives what it printed. The script writes the ID of a program it leaves
        /// running to `$1/child`. The call has to end within 2 seconds, the child must have no
        /// signal blocked, and the port must be free again once the socket closes, so the child
        /// never got it.
        static func runLeavingAChild(_ script: String) async throws -> String {
            let folder = URL.temporaryDirectory.appending(path: "ReqlyTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let listening = try #require(listen(port: 0))
            var isListening = true
            defer {
                if isListening {
                    close(listening.socket)
                }
            }
            let start = ContinuousClock.now
            let printed: Result<String, any Error>
            do {
                printed = .success(try await Tool.run(URL(filePath: "/bin/sh"), ["-c", script, "sh", folder.path]))
            } catch {
                printed = .failure(error)
            }
            #expect(ContinuousClock.now - start < .seconds(2))
            let written = try? String(contentsOf: folder.appending(path: "child"), encoding: .utf8)
            let child = try #require(written.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
            defer { kill(child, SIGKILL) }
            let status = try String(contentsOfFile: "/proc/\(child)/status", encoding: .utf8)
            #expect(status.contains("SigBlk:\t0000000000000000\n"))
            close(listening.socket)
            isListening = false
            // Another test's tool may be starting meanwhile, and a new program has every descriptor
            // until its first steps close them, so the port may take a moment to come free.
            var again = listen(port: listening.port)
            for _ in 0..<100 where again == nil {
                try await Task.sleep(for: .milliseconds(10))
                again = listen(port: listening.port)
            }
            #expect(again != nil, "The port is still taken")
            if let again {
                close(again.socket)
            }
            return try printed.get()
        }

        /// Listens on `port` on 127.0.0.1, or on a free one for 0, as Reqly's proxy does: without
        /// close-on-exec, as SwiftNIO opens its sockets on Linux. Gives the socket and its port.
        static func listen(port: UInt16) -> (socket: Int32, port: UInt16)? {
            let socket = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            guard socket >= 0 else { return nil }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
            address.sin_port = port.bigEndian
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    bind(socket, address, length) == 0 && Glibc.listen(socket, 1) == 0
                        && getsockname(socket, address, &length) == 0
                }
            }
            guard bound else {
                close(socket)
                return nil
            }
            return (socket, UInt16(bigEndian: address.sin_port))
        }
    #endif

    @Test func writesCertificatesAsPEM() {
        let pem = Data([0x30, 0x82, 0x01, 0x0A]).pemCertificate
        #expect(pem == "-----BEGIN CERTIFICATE-----\nMIIBCg==\n-----END CERTIFICATE-----\n")
    }
}
