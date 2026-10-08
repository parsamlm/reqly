import Darwin
import Foundation
import ReqlyModel
import Testing

@testable import SourceResolver

@Suite(.timeLimit(.minutes(1))) struct SourceResolverTests {
    @Test func creditsAppsHelpersServicesAndTools() {
        func program(_ path: String) -> Program { Program(path: path) }
        #expect(program("/Applications/Safari.app/Contents/MacOS/Safari") == .app(bundle: "/Applications/Safari.app"))
        // A helper app counts as the app that holds it.
        let chromeHelper =
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/131.0"
            + "/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        #expect(program(chromeHelper) == .app(bundle: "/Applications/Google Chrome.app"))
        let firefoxHelper =
            "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container"
        #expect(program(firefoxHelper) == .app(bundle: "/Applications/Firefox.app"))
        // An app that merely ships inside another one counts as itself, and so does a tool.
        let python =
            "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9"
            + "/Resources/Python.app/Contents/MacOS/Python"
        #expect(program(python) == .app(bundle: String(python.dropLast("/Contents/MacOS/Python".count))))
        #expect(program("/Applications/Xcode.app/Contents/Developer/usr/bin/git") == .tool)
        #expect(program("/usr/bin/curl") == .tool)
        // An iPhone app in the Simulator keeps its program right inside its bundle.
        let simulated = "/Users/me/Library/Developer/CoreSimulator/Devices/1/data/Containers/Bundle/Application/2"
        #expect(program(simulated + "/Weatherly.app/Weatherly") == .app(bundle: simulated + "/Weatherly.app"))

        let webKit =
            "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc"
            + "/Contents/MacOS/com.apple.WebKit.Networking"
        #expect(program(webKit) == .service)
        #expect(Program.outermostApp(in: webKit) == nil)
        let widget = "/Applications/Weatherly.app/Contents/PlugIns/Widget.appex/Contents/MacOS/Widget"
        #expect(program(widget) == .service)
        #expect(Program.outermostApp(in: widget) == "/Applications/Weatherly.app")
    }

    @Test func findsTheProcessAtTheOtherEndOfAConnection() async throws {
        let listener = try LoopbackSocket.listen()
        defer { close(listener.descriptor) }
        let client = try LoopbackSocket.connect(to: listener.port)
        defer { close(client.descriptor) }

        let owners = ProcessTable.owners(ofConnectionsTo: [listener.port])
        #expect(owners[ProcessTable.Endpoint(clientPort: client.port, proxyPort: listener.port)] == getpid())

        let source = await SourceResolver().source(ofClientPort: client.port, proxyPort: listener.port)
        // The tests run in a tool, unless a test runner app hosts them.
        let program = try #require(ProcessTable.path(of: getpid()))
        if case .app(let bundle) = Program(path: program) {
            #expect(source?.path == bundle)
        } else {
            #expect(source == Source(name: URL(filePath: program).lastPathComponent, path: program))
        }
    }

    @Test func readsTheArgumentsAProcessStartedWith() throws {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(2).littleEndian) { bytes += $0 }
        bytes += Array("/usr/bin/curl".utf8) + [0, 0, 0]
        for string in ["curl", "-v", "HOME=/Users/me"] {
            bytes += Array(string.utf8) + [0]
        }
        #expect(ProcessTable.parseArguments(bytes) == ["curl", "-v"])

        let process = Process()
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        defer { process.terminate() }
        #expect(ProcessTable.arguments(of: process.processIdentifier) == ["/bin/sleep", "10"])
        #expect(ProcessTable.parent(of: process.processIdentifier) == getpid())
        #expect(ProcessTable.processes(running: { $0 == "/bin/sleep" }).contains(process.processIdentifier))
    }

    @Test func tellsSimulatorsAndEmulatorsApart() {
        let udid = "4E2F4C35-9B5A-4F6C-9D11-0B4E4C2B9A11"
        let devices = "/Users/me/Library/Developer/CoreSimulator/Devices"
        let app = "\(devices)/\(udid)/data/Containers/Bundle/Application/X/Weatherly.app/Weatherly"
        let simulator = Devices.device(of: app, arguments: { nil }, ancestorArguments: { [] }, emulators: { [] })
        #expect(simulator?.id == udid)
        #expect(simulator?.kind == .simulator)

        // The simulator's own programs descend from its launchd_sim.
        let runtime = "/Library/Developer/CoreSimulator/Volumes/iOS_23E254a/Library/Developer/CoreSimulator/Profiles"
        let daemon = "\(runtime)/Runtimes/iOS 26.4.simruntime/Contents/Resources/RuntimeRoot/usr/libexec/nsurlsessiond"
        let launchd = ["launchd_sim", "\(devices)/\(udid)/data/var/run/launchd_bootstrap.plist"]
        #expect(
            Devices.device(of: daemon, arguments: { nil }, ancestorArguments: { [[], launchd] }, emulators: { [] })?.id
                == udid)

        let qemu = "/Users/me/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64"
        let pixel = [qemu, "-avd", "Pixel_10_Pro_XL", "-no-snapshot"]
        let pixelDevice = Device(id: "emulator:Pixel_10_Pro_XL", kind: .emulator, name: "Pixel 10 Pro XL")
        #expect(
            Devices.device(of: qemu, arguments: { pixel }, ancestorArguments: { [] }, emulators: { [] }) == pixelDevice)

        // The Mac's own programs run on no device, and nothing more is read about them.
        let curl = Devices.device(
            of: "/usr/bin/curl",
            arguments: {
                Issue.record("Read curl's arguments"); return nil
            },
            ancestorArguments: {
                Issue.record("Read curl's parents"); return []
            },
            emulators: {
                Issue.record("Looked for emulators"); return []
            })
        #expect(curl == nil)
    }

    @Test func creditsAnEmulatorsWiFiToTheEmulator() {
        // netsimd carries an emulator's Wi-Fi. The first emulator starts it, so it runs under that
        // emulator's qemu, and without the name of the virtual device in its arguments.
        let netsimd = "/Users/me/Library/Android/sdk/emulator/netsimd"
        let qemu = "/Users/me/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless"
        let pixel = [qemu, "-avd", "Pixel_10_Pro_XL", "-no-snapshot"]
        let pixelDevice = Device(id: "emulator:Pixel_10_Pro_XL", kind: .emulator, name: "Pixel 10 Pro XL")
        func device(ancestors: [[String]], emulators: [[String]]) -> Device? {
            Devices.device(
                of: netsimd, arguments: { [netsimd, "--host-dns=127.0.0.1"] }, ancestorArguments: { ancestors },
                emulators: { emulators })
        }
        // Its traffic goes with the qemu's own, under the same device.
        #expect(device(ancestors: [pixel, ["emulator", "@Pixel_10_Pro_XL"]], emulators: [pixel]) == pixelDevice)
        // It keeps serving the other emulators after the one that started it quits.
        #expect(device(ancestors: [], emulators: [pixel]) == pixelDevice)
        // Two instances of one virtual device are one device, as their qemus' traffic is.
        #expect(device(ancestors: [pixel], emulators: [pixel, pixel + ["-read-only"]]) == pixelDevice)

        // It's an emulator still, never a Mac tool, when it's not clear which emulator it works for.
        let anyEmulator = Device(id: "emulator:Android Emulator", kind: .emulator, name: "Android Emulator")
        let other = [qemu, "-avd", "Medium_Phone", "-no-snapshot"]
        #expect(device(ancestors: [pixel], emulators: [pixel, other]) == anyEmulator)
        #expect(device(ancestors: [], emulators: []) == anyEmulator)
        // A virtual machine that isn't an Android emulator doesn't count.
        let virtualMachine = ["/opt/homebrew/bin/qemu-system-aarch64", "-name", "linux", "-m", "4096"]
        #expect(device(ancestors: [], emulators: [pixel, virtualMachine]) == pixelDevice)
    }

    @Test func findsTheHardwareAddressesOfNeighbors() throws {
        // What arp says, such as "? (192.168.1.1) at a4:83:e7:2:34:56 on en0 ifscope [ethernet]".
        let arp = Process()
        arp.executableURL = URL(filePath: "/usr/sbin/arp")
        arp.arguments = ["-an"]
        let output = Pipe()
        arp.standardOutput = output
        try arp.run()
        arp.waitUntilExit()
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline)
        // Some test runners see an empty table; then there's nothing to compare.
        for line in lines {
            let fields = line.split(separator: " ")
            guard fields.count > 3, fields[2] == "at", fields[3].contains(":") else { continue }
            let ip = fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            let hardware = fields[3].split(separator: ":").map { $0.count == 1 ? "0\($0)" : String($0) }
                .joined(separator: ":")
            #expect(NetworkNeighbors.hardwareAddress(of: ip) == hardware, "\(ip)")
        }
        #expect(NetworkNeighbors.hardwareAddress(of: "not an address") == nil)
        #expect(NetworkNeighbors.hardwareAddress(of: "203.0.113.24") == nil)
    }

    @Test func findsNothingForAConnectionThatIsGone() async throws {
        let listener = try LoopbackSocket.listen()
        defer { close(listener.descriptor) }
        let client = try LoopbackSocket.connect(to: listener.port)
        close(client.descriptor)

        #expect(await SourceResolver().source(ofClientPort: client.port, proxyPort: listener.port) == nil)
    }
}

/// A TCP socket on 127.0.0.1, made with the system's socket calls.
struct LoopbackSocket {
    var descriptor: Int32
    var port: Int

    struct Failure: Error {}

    static func listen() throws -> LoopbackSocket {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = loopback(port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard descriptor >= 0, bound == 0, Darwin.listen(descriptor, 4) == 0 else { throw Failure() }
        return LoopbackSocket(descriptor: descriptor, port: localPort(of: descriptor))
    }

    /// A connection to `port`. The listener's backlog takes it, so nothing needs to accept it.
    static func connect(to port: Int) throws -> LoopbackSocket {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = loopback(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard descriptor >= 0, connected == 0 else { throw Failure() }
        return LoopbackSocket(descriptor: descriptor, port: localPort(of: descriptor))
    }

    private static func loopback(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    private static func localPort(of descriptor: Int32) -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
