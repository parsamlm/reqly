#if os(macOS)
    import Foundation

    /// A running iOS, iPadOS, watchOS, tvOS or visionOS Simulator.
    public struct Simulator: Hashable, Sendable, Identifiable {
        /// The simulator's UDID.
        public var id: String
        public var name: String
        /// Such as "iOS 26.4".
        public var runtime: String

        public init(id: String, name: String, runtime: String) {
            self.id = id
            self.name = name
            self.runtime = runtime
        }
    }

    /// The Mac's simulators, through Xcode's `simctl`.
    public struct Simulators: Sendable {
        /// Xcode's Developer folder, such as `/Applications/Xcode.app/Contents/Developer`. Without
        /// one, the folder `xcode-select` chose is used, which may have no simulators.
        public var developerDirectory: URL?

        public init(developerDirectory: URL?) {
            self.developerDirectory = developerDirectory
        }

        /// The simulators that are running now.
        public func booted() async throws -> [Simulator] {
            try Self.parse(Data(try await simctl(["list", "devices", "booted", "--json"]).utf8))
        }

        /// Adds Reqly's certificate to a running simulator's keychain, trusted for HTTPS.
        public func installCertificate(der: [UInt8], on udid: String) async throws {
            let file = FileManager.default.temporaryDirectory.appending(path: "Reqly CA \(UUID().uuidString).pem")
            try Data(Data(der).pemCertificate.utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            _ = try await simctl(["keychain", udid, "add-root-cert", file.path(percentEncoded: false)])
        }

        private func simctl(_ arguments: [String]) async throws -> String {
            var environment: [String: String] = [:]
            if let developerDirectory {
                environment["DEVELOPER_DIR"] = developerDirectory.path(percentEncoded: false)
            }
            return try await Tool.run(URL(filePath: "/usr/bin/xcrun"), ["simctl"] + arguments, environment: environment)
        }

        /// The booted simulators in `simctl list devices --json`.
        static func parse(_ json: Data) throws -> [Simulator] {
            struct List: Decodable {
                var devices: [String: [Entry]]
            }
            struct Entry: Decodable {
                var udid: String
                var name: String
                var state: String
            }
            let list = try JSONDecoder().decode(List.self, from: json)
            return list.devices.flatMap { runtime, entries in
                entries.filter { $0.state == "Booted" }.map {
                    Simulator(id: $0.udid, name: $0.name, runtime: runtimeName(runtime))
                }
            }
            .sorted { ($0.runtime, $0.name) < ($1.runtime, $1.name) }
        }

        /// Such as "iOS 26.4", for `com.apple.CoreSimulator.SimRuntime.iOS-26-4`.
        static func runtimeName(_ identifier: String) -> String {
            let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
            let parts = last.split(separator: "-")
            guard let platform = parts.first, parts.count > 1 else { return last }
            return "\(platform) \(parts.dropFirst().joined(separator: "."))"
        }
    }
#endif
