import Foundation
import HelperProtocol
import SystemConfiguration

/// A network service's proxy settings while Reqly captures. Only the HTTP and HTTPS proxy
/// change; everything else stays as the user set it, including the hosts to bypass.
public enum ProxySettings {
    public static let host = "127.0.0.1"

    public static func capturing(_ original: [String: Any], port: Int) -> [String: Any] {
        var settings = original
        settings[kSCPropNetProxiesHTTPEnable as String] = 1
        settings[kSCPropNetProxiesHTTPProxy as String] = host
        settings[kSCPropNetProxiesHTTPPort as String] = port
        settings[kSCPropNetProxiesHTTPSEnable as String] = 1
        settings[kSCPropNetProxiesHTTPSProxy as String] = host
        settings[kSCPropNetProxiesHTTPSPort as String] = port
        return settings
    }
}

/// One network service, such as Wi-Fi, and its proxy settings.
public struct NetworkService {
    public var id: String
    public var proxies: [String: Any]

    public init(id: String, proxies: [String: Any]) {
        self.id = id
        self.proxies = proxies
    }
}

/// Reads and changes the Mac's network settings.
public protocol NetworkSettings {
    func enabledServices() throws -> [NetworkService]
    /// Replaces the proxy settings of each service, by service ID. Services that no longer
    /// exist are skipped.
    func apply(_ proxies: [String: [String: Any]]) throws
}

/// The real network settings, through System Configuration. Changing them needs root.
public struct SystemNetworkSettings: NetworkSettings {
    public init() {}

    public func enabledServices() throws -> [NetworkService] {
        guard let preferences = SCPreferencesCreate(nil, "ReqlyHelper" as CFString, nil),
            let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService]
        else { throw HelperError.cannotReadSettings }
        return services.compactMap { service in
            guard SCNetworkServiceGetEnabled(service),
                let id = SCNetworkServiceGetServiceID(service) as String?,
                let proxies = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
            else { return nil }
            return NetworkService(id: id, proxies: SCNetworkProtocolGetConfiguration(proxies) as? [String: Any] ?? [:])
        }
    }

    public func apply(_ proxies: [String: [String: Any]]) throws {
        guard let preferences = SCPreferencesCreate(nil, "ReqlyHelper" as CFString, nil),
            SCPreferencesLock(preferences, true)
        else { throw HelperError.cannotChangeSettings }
        defer { SCPreferencesUnlock(preferences) }
        for (id, settings) in proxies {
            guard let service = SCNetworkServiceCopy(preferences, id as CFString),
                let protocolSettings = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
            else { continue }
            guard SCNetworkProtocolSetConfiguration(protocolSettings, settings as CFDictionary) else {
                throw HelperError.cannotChangeSettings
            }
        }
        guard SCPreferencesCommitChanges(preferences), SCPreferencesApplyChanges(preferences) else {
            throw HelperError.cannotChangeSettings
        }
    }
}
