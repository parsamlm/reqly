import AppKit
import Foundation
import Observation
import ReqlyModel
import Sparkle

/// Keeps Reqly up to date. A copy with the public half of the key that signs updates installs new
/// versions in place with Sparkle, from the appcast each release publishes. Any other copy, such
/// as one built from source, looks for the newest release on GitHub and says when one is out.
/// Either way, a check reads the newest version and nothing else: Reqly sends nothing about you or
/// your traffic.
@Observable
final class UpdatesModel: NSObject {
    enum Status: Equatable {
        case notChecked
        case checking
        case upToDate
        case available(AppVersion, page: URL)
        case failed(String)
    }

    private(set) var status = Status.notChecked
    private(set) var lastChecked: Date?

    /// This copy's version, such as "1.0".
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

    static let latestRelease = URL(string: "https://api.github.com/repos/parsamlm/reqly/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/parsamlm/reqly/releases")!

    /// Sparkle, in a copy that installs updates in place.
    @ObservationIgnored private var sparkle: SPUStandardUpdaterController?

    override init() {
        lastChecked = UserDefaults.standard.object(forKey: DefaultsKey.lastUpdateCheck) as? Date
        super.init()
        if Self.installsUpdates {
            let controller = SPUStandardUpdaterController(
                startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
            controller.updater.automaticallyChecksForUpdates = Self.checksAutomatically
            controller.startUpdater()
            sparkle = controller
            #if DEBUG
                if UserDefaults.standard.bool(forKey: DefaultsKey.checkForUpdatesAtLaunch) {
                    controller.updater.checkForUpdatesInBackground()
                }
            #endif
        } else if Self.checksAutomatically, (lastChecked ?? .distantPast) < Date.now.addingTimeInterval(-86_400) {
            // Once a day at most, when Reqly opens.
            Task { await check() }
        }
    }

    /// Whether this copy installs updates in place: it has the public half of the key that
    /// signs them.
    static var installsUpdates: Bool {
        !(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").isEmpty
    }

    var installsUpdates: Bool { sparkle != nil }

    /// Whether Reqly looks for updates on its own. It does unless you turn it off.
    static var checksAutomatically: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: DefaultsKey.checksForUpdates) == nil
            || defaults.bool(forKey: DefaultsKey.checksForUpdates)
    }

    /// Follows the setting in Settings › General.
    func setChecksAutomatically(_ isOn: Bool) {
        sparkle?.updater.automaticallyChecksForUpdates = isOn
    }

    var updateAvailable: (version: AppVersion, page: URL)? {
        if case .available(let version, let page) = status { (version, page) } else { nil }
    }

    func check() async {
        if let sparkle {
            // Sparkle shows its own window: the new version, or that this one is up to date.
            sparkle.checkForUpdates(nil)
            return
        }
        guard status != .checking else { return }
        status = .checking
        var request = URLRequest(url: Self.latestRelease, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Reqly/\(version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200:
                let release = try JSONDecoder().decode(Release.self, from: data)
                if let latest = AppVersion(release.tagName), let current = AppVersion(version), latest > current {
                    status = .available(latest, page: release.page)
                } else {
                    status = .upToDate
                }
            case 404:
                status = .failed("There are no releases on GitHub yet.")
            case let code:
                status = .failed("GitHub answered with \(code ?? 0). Try again later.")
            }
        } catch {
            status = .failed("Reqly couldn't reach GitHub. Check your internet connection, then try again.")
        }
        noteChecked()
    }

    /// Installs the new version with Sparkle, or opens its page to download it.
    func download() {
        if let sparkle {
            sparkle.checkForUpdates(nil)
        } else {
            NSWorkspace.shared.open(updateAvailable?.page ?? Self.releasesPage)
        }
    }

    private func noteChecked() {
        lastChecked = .now
        UserDefaults.standard.set(lastChecked, forKey: DefaultsKey.lastUpdateCheck)
    }

    private struct Release: Decodable {
        let tagName: String
        let page: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case page = "html_url"
        }
    }
}

/// What Sparkle found, for Settings and the menu-bar item to show.
extension UpdatesModel: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        if let found = AppVersion(item.displayVersionString) {
            status = .available(found, page: item.fullReleaseNotesURL ?? Self.releasesPage)
        }
        noteChecked()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        status = .upToDate
        noteChecked()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        // Sparkle reports finding nothing new this way too.
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain, nsError.code == Int(SUError.noUpdateError.rawValue) {
            status = .upToDate
        } else {
            status = .failed(nsError.localizedDescription)
        }
        noteChecked()
    }
}
