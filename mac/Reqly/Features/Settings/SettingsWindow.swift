import AppKit
import Observation
import SwiftUI

/// Reqly's Settings window.
struct SettingsWindow: View {
    enum Pane: String, CaseIterable {
        case general, https, upstreamProxy, reverseProxy, clientCertificates, protobuf
    }

    @Environment(SettingsNavigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.pane) {
            Tab("General", systemImage: "gearshape", value: .general) {
                GeneralSettings()
            }
            Tab("HTTPS", systemImage: "lock", value: .https) {
                HTTPSSettings()
            }
            Tab("Upstream Proxy", systemImage: "arrow.triangle.branch", value: .upstreamProxy) {
                UpstreamProxySettings()
            }
            Tab("Reverse Proxy", systemImage: "arrow.left.arrow.right", value: .reverseProxy) {
                ReverseProxySettings()
            }
            Tab("Client Certificates", systemImage: "person.text.rectangle", value: .clientCertificates) {
                ClientCertificateSettings()
            }
            Tab("Protobuf", systemImage: "curlybraces.square", value: .protobuf) {
                ProtobufSettings()
            }
        }
        .frame(width: 680, height: 600)
    }
}

/// Which pane Settings shows, so other windows can open Settings on the one they mean.
@Observable
final class SettingsNavigation {
    var pane = SettingsNavigation.firstPane

    private static var firstPane: SettingsWindow.Pane {
        #if DEBUG
            if let name = UserDefaults.standard.string(forKey: DefaultsKey.showSettings),
                let pane = SettingsWindow.Pane(rawValue: name)
            {
                return pane
            }
        #endif
        return .general
    }
}

extension SettingsNavigation {
    /// Opens Settings on a pane, from any window.
    func open(_ pane: SettingsWindow.Pane, with openSettings: OpenSettingsAction) {
        self.pane = pane
        openSettings()
        NSApp.activate()
    }
}
