#if os(Windows)
    import CoreInterface
    import DeviceBridge
    import Foundation
    import ReqlyModel
    import Testing
    import WinSDK

    @Suite struct WindowsCaptureTests {
        /// Sends a request through the proxy on `port`, as an app would, and reads the answer.
        static func sendRequest(throughProxyAt port: Int) throws {
            _ = try send("http://127.0.0.1:9/", host: "127.0.0.1:9", throughProxyAt: port)
        }

        /// Sends a GET for `url` through the proxy on `port`, as an app would, and returns the answer,
        /// or what came of it in five seconds.
        static func send(_ url: String, host: String, throughProxyAt port: Int) throws -> String {
            var data = WSADATA()
            #expect(WSAStartup(0x0202, &data) == 0)
            defer { WSACleanup() }
            let client = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
            defer { closesocket(client) }
            var address = sockaddr_in()
            address.sin_family = ADDRESS_FAMILY(AF_INET)
            address.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian
            address.sin_port = UInt16(port).bigEndian
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(client, $0, Int32(MemoryLayout<sockaddr_in>.size))
                }
            }
            try #require(connected == 0)
            var timeout: DWORD = 5000
            _ = withUnsafeBytes(of: &timeout) { value in
                let bytes = value.baseAddress?.assumingMemoryBound(to: CChar.self)
                return setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, bytes, Int32(value.count))
            }
            // With no server there, Reqly answers itself, and the exchange is recorded all the same.
            let request = Array("GET \(url) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n".utf8)
            _ = request.withUnsafeBufferPointer { bytes in
                bytes.withMemoryRebound(to: CChar.self) { WinSDK.send(client, $0.baseAddress, Int32($0.count), 0) }
            }
            var answer: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBufferPointer { bytes in
                    bytes.withMemoryRebound(to: CChar.self) { recv(client, $0.baseAddress, Int32($0.count), 0) }
                }
                guard count > 0 else { break }
                answer += buffer[..<Int(count)]
            }
            return String(decoding: answer, as: UTF8.self)
        }

        /// A connection that stays open, as a browser keeps one to its proxy.
        static func openConnection(toProxyAt port: Int) throws -> SOCKET {
            var data = WSADATA()
            #expect(WSAStartup(0x0202, &data) == 0)
            let client = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
            var address = sockaddr_in()
            address.sin_family = ADDRESS_FAMILY(AF_INET)
            address.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian
            address.sin_port = UInt16(port).bigEndian
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(client, $0, Int32(MemoryLayout<sockaddr_in>.size))
                }
            }
            try #require(connected == 0)
            return client
        }

        @Test func capturesAgainOnTheSamePort() async throws {
            let folder = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let host = try await SessionHost.open(OpenOptions(sessionsFolder: folder.path), send: { _ in })
            let start = #"{"call":"startCapturing","port":9193}"#
            #expect(try result(await call(host, start))["port"] as? Int == 9193)
            try await Task.detached { try Self.sendRequest(throughProxyAt: 9193) }.value
            let open = try await Task.detached { try Self.openConnection(toProxyAt: 9193) }.value
            defer {
                closesocket(open)
                WSACleanup()
            }
            _ = try result(await call(host, #"{"call":"stopCapturing"}"#))
            // Starting again right away, on the same port, while a connection from before is still open.
            let again = await call(host, start)
            #expect(try problem(again) == nil, "\(String(decoding: again, as: UTF8.self))")
            #expect(await host.capture.isCapturing)
            await host.close()
        }

        @Test func namesTheAppThatSentARequest() async throws {
            let folder = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let log = EventLog()
            // Finding apps is on unless turned off; the proxy setting stays as it is.
            let host = try await SessionHost.open(OpenOptions(sessionsFolder: folder.path), send: log.record)
            let started = try result(await call(host, #"{"call":"startCapturing","port":0}"#))
            let port = try #require(started["port"] as? Int)
            try await Task.detached { try Self.sendRequest(throughProxyAt: port) }.value

            let id = try #require(
                await log.wait { event in
                    (event["steps"] as? [[String: Any]])?.contains { $0["inserted"] != nil } == true
                }.flatMap { event in
                    (event["steps"] as? [[String: Any]])?.compactMap { $0["inserted"] as? [[String: Any]] }.first?
                        .first?["id"] as? Int
                })
            // The app shows once the connection's owner is found, in a later change.
            var row: [String: Any]?
            for _ in 0..<100 {
                let rows = try result(await call(host, #"{"call":"rows","ids":[\#(id)]}"#))["rows"] as? [[String: Any]]
                if let first = rows?.first, first["app"] != nil {
                    row = first
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            let found = try #require(row)
            #expect((found["appPath"] as? String)?.lowercased().hasSuffix(".exe") == true)
            #expect(found["host"] as? String == "127.0.0.1")
            await host.close()
        }

        @Test func letsAnAppsHeldRequestGoOnWhenYouClear() async throws {
            let folder = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let log = EventLog()
            let host = try await SessionHost.open(
                OpenOptions(sessionsFolder: folder.path, findsApps: false), send: log.record)
            let rules = RuleSet(
                rules: [
                    Rule(
                        id: UUID(), name: "Hold the weather", isOn: true, match: RequestMatch(host: "weather.invalid"),
                        action: .breakpoint(.request))
                ], kindsOn: [.breakpoint])
            let json = String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)
            _ = try result(await call(host, #"{"call":"setRules","rules":\#(json)}"#))
            let started = try result(await call(host, #"{"call":"startCapturing","port":0}"#))
            let port = try #require(started["port"] as? Int)
            // .invalid never resolves, so nothing leaves the computer.
            let sending = Task.detached {
                try Self.send("http://weather.invalid/v2/held", host: "weather.invalid", throughProxyAt: port)
            }
            #expect(await log.wait { $0["event"] as? String == "paused" } != nil)
            // Clearing takes the request's row away, and with it the only way to decide, so it goes
            // on as it came, and the app gets its answer.
            _ = try result(await call(host, #"{"call":"clear"}"#))
            let answer = try await sending.value
            #expect(answer.hasPrefix("HTTP/1.1 502"), "\(answer.prefix(200))")
            await host.close()
        }

        /// A server on this PC that answers each request with "ok", one at a time, until it stops.
        final class OkServer: @unchecked Sendable {
            // The socket is this object's own; it's read only to accept, and closed once, in `stop`.
            private let listener: SOCKET
            let port: Int

            init() throws {
                var data = WSADATA()
                #expect(WSAStartup(0x0202, &data) == 0)
                let listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
                var address = sockaddr_in()
                address.sin_family = ADDRESS_FAMILY(AF_INET)
                address.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian
                var length = Int32(MemoryLayout<sockaddr_in>.size)
                let listening = withUnsafeMutablePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        bind(listener, address, length) == 0 && listen(listener, 4) == 0
                            && getsockname(listener, address, &length) == 0
                    }
                }
                try #require(listening)
                self.listener = listener
                port = Int(UInt16(bigEndian: address.sin_port))
                Thread.detachNewThread {
                    while true {
                        let client = accept(listener, nil, nil)
                        guard client != INVALID_SOCKET else { return }
                        var buffer = [CChar](repeating: 0, count: 4096)
                        _ = recv(client, &buffer, Int32(buffer.count), 0)
                        let answer = Array(
                            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
                        _ = answer.withUnsafeBufferPointer { bytes in
                            bytes.withMemoryRebound(to: CChar.self) {
                                WinSDK.send(client, $0.baseAddress, Int32($0.count), 0)
                            }
                        }
                        closesocket(client)
                    }
                }
            }

            func stop() {
                closesocket(listener)
                WSACleanup()
            }
        }

        @Test func letsAHeldResponseGoOnAfterYouClear() async throws {
            let server = try OkServer()
            defer { server.stop() }
            let folder = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let log = EventLog()
            let host = try await SessionHost.open(
                OpenOptions(sessionsFolder: folder.path, findsApps: false), send: log.record)
            let rules = RuleSet(
                rules: [
                    Rule(
                        id: UUID(), name: "Hold both", isOn: true, match: RequestMatch(host: "127.0.0.1"),
                        action: .breakpoint(.both))
                ], kindsOn: [.breakpoint])
            let json = String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)
            _ = try result(await call(host, #"{"call":"setRules","rules":\#(json)}"#))
            let started = try result(await call(host, #"{"call":"startCapturing","port":0}"#))
            let port = try #require(started["port"] as? Int)
            let origin = "127.0.0.1:\(server.port)"
            let sending = Task.detached {
                try Self.send("http://\(origin)/held", host: origin, throughProxyAt: port)
            }
            #expect(await log.wait { $0["event"] as? String == "paused" } != nil)
            // Clearing lets the request go on. Its response would be held next, with no row to show
            // it, so it goes on too, and the app gets the server's answer.
            _ = try result(await call(host, #"{"call":"clear"}"#))
            let answer = try await sending.value
            #expect(answer.hasPrefix("HTTP/1.1 200") && answer.hasSuffix("ok"), "\(answer.prefix(200))")
            await host.close()
        }

        @Test func creditsAnEmulatorsTrafficToTheEmulator() async throws {
            // A stand-in for an Android emulator: Windows' own curl, under the name of the emulator's
            // program. `@Pixel_9`, as Android Studio starts a virtual device, goes in its arguments
            // as the user agent it sends.
            let curl = URL(fileURLWithPath: #"C:\Windows\System32\curl.exe"#)
            try #require(FileManager.default.fileExists(atPath: curl.path))
            let folder = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let emulator = folder.appending(path: "qemu-system-x86_64.exe")
            try FileManager.default.copyItem(at: curl, to: emulator)

            let log = EventLog()
            let sessions = folder.appending(path: "Sessions")
            let host = try await SessionHost.open(OpenOptions(sessionsFolder: sessions.path), send: log.record)
            let started = try result(await call(host, #"{"call":"startCapturing","port":0}"#))
            let port = try #require(started["port"] as? Int)
            // Started as Reqly starts adb, so it gets none of the sockets other tests have open.
            // Port 9 has no server, so Reqly answers itself, and the exchange is recorded all the same.
            _ = try await Tool.run(
                emulator,
                [
                    "--silent", "--output", "NUL", "--max-time", "10", "--proxy", "http://127.0.0.1:\(port)",
                    "--user-agent", "@Pixel_9", "http://127.0.0.1:9/",
                ])

            // The device shows once the connection's owner is found, in a later change.
            var row: [String: Any]?
            for _ in 0..<100 {
                let ids = try result(await call(host, #"{"call":"rowIDs"}"#))["ids"] as? [Int] ?? []
                let rows = try result(await call(host, #"{"call":"rows","ids":\#(ids)}"#))["rows"] as? [[String: Any]]
                if let first = rows?.first, first["device"] != nil {
                    row = first
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            let found = try #require(row)
            #expect(found["device"] as? String == "Pixel 9")
            // The emulator's own program isn't an app.
            #expect(found["app"] == nil)
            await host.close()
        }
    }
#endif
