#if os(macOS)
    import Darwin
    import Foundation
    import ReqlyModel

    /// Finds which app or command-line tool opened a connection to Reqly, and the simulator or
    /// emulator it runs in.
    ///
    /// It looks up the process at the connection's other end, then the app that process belongs
    /// to. Lookups that arrive together share one pass over the process table.
    public actor SourceResolver {
        private struct Lookup: Sendable {
            var endpoint: ProcessTable.Endpoint
            var continuation: CheckedContinuation<pid_t?, Never>
        }

        /// Lookups waiting for the next pass.
        private var waiting: [Lookup] = []
        private var isScanning = false
        /// Apps by bundle path, since reading a bundle takes a moment.
        private var apps: [String: Source] = [:]
        /// The simulator or emulator each process runs in, by process and its program.
        private var devices: [pid_t: (path: String, device: Device?)] = [:]

        public init() {}

        /// What opened the connection from `clientPort` on this Mac to Reqly's `proxyPort`. It's
        /// `nil` when the connection has closed already, or belongs to another user's process.
        public func source(ofClientPort clientPort: Int, proxyPort: Int) async -> Source? {
            await origin(ofClientPort: clientPort, proxyPort: proxyPort)?.source
        }

        /// What opened the connection, and the simulator or emulator it runs in, if any.
        public func origin(ofClientPort clientPort: Int, proxyPort: Int) async -> Origin? {
            let endpoint = ProcessTable.Endpoint(clientPort: clientPort, proxyPort: proxyPort)
            guard let pid = await owner(of: endpoint), let path = ProcessTable.path(of: pid) else { return nil }
            let device = device(of: pid, path: path)
            // An emulator's own process isn't an app: the app runs inside it, out of sight.
            if device?.kind == .emulator {
                return Origin(device: device)
            }
            return Origin(source: source(of: pid), device: device)
        }

        /// The simulator or Android emulator a process belongs to.
        private func device(of pid: pid_t, path: String) -> Device? {
            if let known = devices[pid], known.path == path {
                return known.device
            }
            if devices.count > 1_000 {
                devices.removeAll()
            }
            let device = Devices.device(
                of: path, arguments: { ProcessTable.arguments(of: pid) },
                ancestorArguments: {
                    var ancestors: [[String]] = []
                    var current = pid
                    for _ in 0..<8 {
                        guard let parent = ProcessTable.parent(of: current) else { break }
                        ancestors.append(ProcessTable.arguments(of: parent) ?? [])
                        current = parent
                    }
                    return ancestors
                },
                emulators: {
                    ProcessTable.processes(running: Devices.isAndroidEmulator).compactMap(ProcessTable.arguments(of:))
                })
            // The emulators netsimd works for come and go, so its device is found afresh each time.
            if !Devices.isEmulatorWiFi(path) {
                devices[pid] = (path, device)
            }
            return device
        }

        private func owner(of endpoint: ProcessTable.Endpoint) async -> pid_t? {
            await withCheckedContinuation { continuation in
                waiting.append(Lookup(endpoint: endpoint, continuation: continuation))
                if !isScanning {
                    scan()
                }
            }
        }

        /// Answers the waiting lookups with one pass over the process table. Lookups that arrive
        /// during the pass wait for the next one, since their connections may be newer.
        private func scan() {
            isScanning = true
            let lookups = waiting
            waiting = []
            let proxyPorts = Set(lookups.map(\.endpoint.proxyPort))
            Task.detached(priority: .userInitiated) {
                let owners = ProcessTable.owners(ofConnectionsTo: proxyPorts)
                await self.finish(lookups, owners: owners)
            }
        }

        private func finish(_ lookups: [Lookup], owners: [ProcessTable.Endpoint: pid_t]) {
            for lookup in lookups {
                lookup.continuation.resume(returning: owners[lookup.endpoint])
            }
            isScanning = false
            if !waiting.isEmpty {
                scan()
            }
        }

        /// The app or tool that a process belongs to.
        private func source(of pid: pid_t) -> Source? {
            guard let path = ProcessTable.path(of: pid) else { return nil }
            switch Program(path: path) {
            case .app(let bundle):
                return app(at: bundle)
            case .service:
                if let responsible = ProcessTable.responsibleProcess(for: pid), responsible != pid,
                    let responsiblePath = ProcessTable.path(of: responsible),
                    case .app(let bundle) = Program(path: responsiblePath)
                {
                    return app(at: bundle)
                }
                return Program.outermostApp(in: path).map(app(at:)) ?? tool(at: path)
            case .tool:
                return tool(at: path)
            }
        }

        private func app(at bundlePath: String) -> Source {
            if let app = apps[bundlePath] {
                return app
            }
            var name = FileManager.default.displayName(atPath: bundlePath)
            if name.hasSuffix(".app") {
                name.removeLast(4)
            }
            let app = Source(name: name, bundleID: Bundle(path: bundlePath)?.bundleIdentifier, path: bundlePath)
            apps[bundlePath] = app
            return app
        }

        private func tool(at path: String) -> Source {
            Source(name: URL(filePath: path).lastPathComponent, path: path)
        }
    }

    /// What kind of program a path holds, which decides where its traffic is credited.
    enum Program: Equatable {
        /// An app, or a helper app inside one. A helper's traffic goes to the app that holds it.
        case app(bundle: String)
        /// An XPC service or app extension, which works for another process.
        case service
        /// A command-line tool, such as curl. A tool that ships inside an app, such as Xcode's
        /// git, still counts as itself, since you run it from Terminal.
        case tool

        /// Where apps keep their helper apps, inside their `Contents` folder.
        private static let helperFolders: Set<Substring> = ["Frameworks", "Helpers", "Library", "MacOS", "PlugIns"]

        init(path: String) {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            if let own = Self.ownApp(in: components) {
                let bundle = Self.hostApp(of: own, in: components) ?? own
                self = .app(bundle: components[...bundle].joined(separator: "/"))
            } else if path.contains(".xpc/") || path.contains(".appex/") {
                self = .service
            } else {
                self = .tool
            }
        }

        /// The app whose executable this is: its program sits in `Contents/MacOS`, or right
        /// inside the bundle for an iPhone app in the Simulator.
        private static func ownApp(in components: [Substring]) -> Int? {
            components.indices.last { index in
                guard components[index].hasSuffix(".app") else { return false }
                let isMacApp =
                    index + 3 == components.count - 1 && components[index + 1] == "Contents"
                    && components[index + 2] == "MacOS"
                return isMacApp || index + 1 == components.count - 1
            }
        }

        /// The outermost app that holds the app at `own` as one of its helpers.
        private static func hostApp(of own: Int, in components: [Substring]) -> Int? {
            components.indices.first { index in
                index < own && components[index].hasSuffix(".app") && index + 2 < own
                    && components[index + 1] == "Contents" && helperFolders.contains(components[index + 2])
            }
        }

        /// The outermost app bundle in a path, such as `/Applications/Weatherly.app` for one of
        /// its extensions.
        static func outermostApp(in path: String) -> String? {
            guard let end = path.range(of: ".app/")?.lowerBound else { return nil }
            return String(path[..<end]) + ".app"
        }
    }

    /// Tells the processes of simulators and Android emulators apart from the Mac's own.
    enum Devices {
        /// - Parameters:
        ///   - arguments: The process's arguments. They're read only for an emulator.
        ///   - ancestorArguments: The arguments of the processes that started it, nearest first.
        ///     They're read only for a simulator's process whose path doesn't name the simulator.
        ///   - emulators: The arguments of each Android emulator that's running. They're read
        ///     only for netsimd.
        static func device(
            of path: String, arguments: () -> [String]?, ancestorArguments: () -> [[String]],
            emulators: () -> [[String]]
        ) -> Device? {
            if isAndroidEmulator(path) {
                return emulator(named: arguments().flatMap(emulatorName(in:)))
            }
            if isEmulatorWiFi(path) {
                // One netsimd serves every emulator that's running: the first one starts it, and
                // the others share it. So its traffic is credited to an emulator by name only while
                // just one is running.
                let names = Set(emulators().compactMap(emulatorName(in:)))
                return emulator(named: names.count == 1 ? names.first : nil)
            }
            guard path.contains("/CoreSimulator/") else { return nil }
            // An app's folder names its simulator. The simulator's own programs, such as its
            // nsurlsessiond, run under its launchd_sim, which starts with a file in the simulator's folder.
            let udid =
                simulatorUDID(in: path) ?? ancestorArguments().lazy.flatMap { $0 }.compactMap(simulatorUDID(in:)).first
            guard let udid else { return nil }
            return Device(id: udid, kind: .simulator, name: simulatorName(udid: udid) ?? "Simulator")
        }

        /// The emulator's program, such as `…/emulator/qemu/darwin-aarch64/qemu-system-aarch64`.
        static func isAndroidEmulator(_ path: String) -> Bool {
            URL(filePath: path).lastPathComponent.hasPrefix("qemu-system-") || path.contains("/emulator/qemu/")
        }

        /// The emulators' netsimd, such as `…/sdk/emulator/netsimd`. It carries their Wi-Fi, which
        /// is the network Android uses first.
        static func isEmulatorWiFi(_ path: String) -> Bool {
            URL(filePath: path).lastPathComponent == "netsimd"
        }

        /// An emulator running the virtual device `name`, or any emulator when that's not known.
        static func emulator(named name: String?) -> Device {
            Device(
                id: "emulator:\(name ?? "Android Emulator")", kind: .emulator,
                name: name.map(readableName) ?? "Android Emulator")
        }

        /// The virtual device the emulator runs, from `-avd Pixel_10` or `@Pixel_10`.
        static func emulatorName(in arguments: [String]) -> String? {
            if let index = arguments.firstIndex(of: "-avd"), arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }
            return arguments.first { $0.hasPrefix("@") && $0.count > 1 }.map { String($0.dropFirst()) }
        }

        /// Such as "Pixel 10 Pro XL" for `Pixel_10_Pro_XL`.
        static func readableName(_ name: String) -> String {
            name.replacingOccurrences(of: "_", with: " ")
        }

        /// The UDID in a path such as `…/CoreSimulator/Devices/<UDID>/data/Containers/…`.
        static func simulatorUDID(in path: String) -> String? {
            guard let range = path.range(of: "/CoreSimulator/Devices/") else { return nil }
            let udid = path[range.upperBound...].prefix { $0 != "/" }
            return UUID(uuidString: String(udid)) != nil ? String(udid) : nil
        }

        /// The name the simulator was given, from its `device.plist`.
        static func simulatorName(udid: String) -> String? {
            let plist = URL.homeDirectory.appending(
                path: "Library/Developer/CoreSimulator/Devices/\(udid)/device.plist")
            guard let data = try? Data(contentsOf: plist),
                let properties = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }
            return properties["name"] as? String
        }
    }
#endif
