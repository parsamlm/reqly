#if os(Windows)
    import Foundation
    import Testing
    import WinSDK
    import WindowsSystem

    @Suite struct AppLookupTests {
        /// A connection over loopback, made with Winsock, the way an app connects to Reqly.
        struct Connection {
            var listener: SOCKET
            var client: SOCKET
            var accepted: SOCKET
            var clientPort: Int
            var listenerPort: Int

            init() throws {
                var data = WSADATA()
                #expect(WSAStartup(0x0202, &data) == 0)
                listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
                var address = sockaddr_in()
                address.sin_family = ADDRESS_FAMILY(AF_INET)
                address.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian
                address.sin_port = 0
                try Self.check(Self.call(listener, &address) { bind($0, $1, $2) })
                try Self.check(listen(listener, 1))
                listenerPort = try Self.port(of: listener)
                address.sin_port = UInt16(listenerPort).bigEndian
                client = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
                try Self.check(Self.call(client, &address) { connect($0, $1, $2) })
                accepted = accept(listener, nil, nil)
                clientPort = try Self.port(of: client)
            }

            func close() {
                closesocket(accepted)
                closesocket(client)
                closesocket(listener)
                WSACleanup()
            }

            struct Failed: Error {
                var code: Int32
            }

            static func check(_ result: Int32) throws {
                if result == SOCKET_ERROR {
                    throw Failed(code: WSAGetLastError())
                }
            }

            static func call(
                _ socket: SOCKET, _ address: inout sockaddr_in,
                _ body: (SOCKET, UnsafePointer<sockaddr>, Int32) -> Int32
            ) -> Int32 {
                withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        body(socket, $0, Int32(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }

            static func port(of socket: SOCKET) throws -> Int {
                var address = sockaddr_in()
                var length = Int32(MemoryLayout<sockaddr_in>.size)
                let result = withUnsafeMutablePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
                }
                try check(result)
                return Int(UInt16(bigEndian: address.sin_port))
            }
        }

        @Test func findsTheAppAtTheOtherEndOfAConnection() throws {
            let connection = try Connection()
            defer { connection.close() }
            let id = AppLookup.processID(clientPort: connection.clientPort, proxyPort: connection.listenerPort)
            #expect(id == GetCurrentProcessId())
            let path = try #require(id.flatMap(AppLookup.path))
            #expect(path.lowercased().hasSuffix(".exe"))
            #expect(!AppLookup.name(ofApp: path).isEmpty)
            let origin = try #require(
                AppLookup().origin(clientPort: connection.clientPort, proxyPort: connection.listenerPort))
            #expect(origin.source?.path == path)
            // The tests run on this PC, not in an emulator.
            #expect(origin.device == nil)
            // A connection that isn't there has no app.
            #expect(AppLookup.processID(clientPort: connection.clientPort, proxyPort: 1) == nil)
        }

        @Test func readsAProcesssArguments() throws {
            // Its own, as Windows split them for it.
            #expect(AppLookup.arguments(of: GetCurrentProcessId()) == CommandLine.arguments)
            #expect(
                AppLookup.split(commandLine: #""C:\Android Sdk\qemu-system-x86_64.exe" -avd Pixel_9 "@My Phone""#)
                    == [#"C:\Android Sdk\qemu-system-x86_64.exe"#, "-avd", "Pixel_9", "@My Phone"])
            // The System Idle Process can't be opened.
            #expect(AppLookup.arguments(of: 0) == nil)

            let path = try #require(AppLookup.path(of: GetCurrentProcessId()))
            let name = try #require(path.split(separator: "\\").last).lowercased()
            #expect(AppLookup.processes(running: { $0.lowercased() == name }).contains(GetCurrentProcessId()))
        }

        @Test func namesAppsByTheirDescription() {
            // Notepad describes itself as Notepad, whatever its file is called.
            let notepad = #"C:\Windows\System32\notepad.exe"#
            if FileManager.default.fileExists(atPath: notepad) {
                #expect(AppLookup.name(ofApp: notepad) == "Notepad")
            }
            #expect(AppLookup.name(ofApp: #"C:\Nowhere\Weather Test.exe"#) == "Weather Test")
        }

        @Test func readsYourProxySettings() throws {
            // Only reads them; the tests never change the computer's settings.
            let settings = try WinINetProxySettings().read()
            #expect(settings.flags & ProxySettings.direct != 0 || settings.flags & ProxySettings.usesProxy != 0)
        }
    }
#endif
