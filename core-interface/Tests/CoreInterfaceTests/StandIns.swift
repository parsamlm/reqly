import CoreInterface
import Foundation
import ReqlyModel

/// Made-up proxy settings, which test runs keep in a file, as the switch would the system's.
struct StandInProxySettings: UserProxySettings, Equatable {
    var proxy: String?

    static let noProxy = StandInProxySettings()

    func capturing(port: Int) -> StandInProxySettings {
        StandInProxySettings(proxy: "127.0.0.1:\(port)")
    }

    func pointsAtReqly(port: Int) -> Bool {
        proxy == "127.0.0.1:\(port)"
    }
}

/// Secrets in a plain JSON file, by name, as a test run of the app keeps them.
struct PlainSecrets: SecretStorage {
    let file: URL

    func load() throws -> [String: Data] {
        guard let stored = try? Data(contentsOf: file) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: stored).compactMapValues {
            Data(base64Encoded: $0)
        }
    }

    func save(_ secrets: [String: Data]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try FileReplacement.write(encoder.encode(secrets.mapValues { $0.base64EncodedString() }), to: file)
    }
}

extension SystemParts {
    /// Stand-ins for the system's parts, so the tests never touch the computer's proxy settings,
    /// certificates or secrets. A session finds no apps and no network addresses.
    static let standIns = SystemParts(
        proxySwitch: { restoreFile, standIn in
            standIn.map {
                UserProxySwitch(settings: FileProxySettings<StandInProxySettings>(file: $0), restoreFile: restoreFile)
            }
        },
        secrets: { file, _ in PlainSecrets(file: file) })
}

extension SessionHost {
    /// Opens a session with stand-ins for the system's parts.
    static func open(
        _ options: OpenOptions, protobuf: ProtobufLibrary = .shared, send: @escaping @Sendable (Data) -> Void
    ) async throws(Problem) -> SessionHost {
        try await open(options, system: .standIns, protobuf: protobuf, send: send)
    }
}
