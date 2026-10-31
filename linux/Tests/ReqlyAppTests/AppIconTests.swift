import Foundation
import LinuxApps
import ReqlyModel
import Testing

@testable import ReqlyApp

@Suite struct AppIconTests {
    /// Desktop entries in a folder of the test's own, read again at every lookup.
    static func entries(_ files: [String: String]) throws -> (DesktopEntries, URL) {
        let folder = URL(filePath: NSTemporaryDirectory()).appending(path: "reqly-icons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
        }
        let entries = DesktopEntries(folders: [.init(path: folder.path)], locales: [], searchPath: [], interval: .zero)
        return (entries, folder)
    }

    static func entry(name: String, icon: String) -> String {
        "[Desktop Entry]\nType=Application\nName=\(name)\nExec=/usr/bin/true\nIcon=\(icon)\n"
    }

    @Test func readsAnEntrysIconAsAThemedNameOrAFile() {
        #expect(AppIcon(entryIcon: "org.gnome.Calculator") == .themed("org.gnome.Calculator"))
        #expect(AppIcon(entryIcon: "firefox.png") == .themed("firefox"))
        #expect(AppIcon(entryIcon: "code.SVG") == .themed("code"))
        #expect(AppIcon(entryIcon: "/snap/firefox/123/default256.png") == .file("/snap/firefox/123/default256.png"))
    }

    @Test func findsTheIconByTheAppsDesktopID() throws {
        let image = URL(filePath: NSTemporaryDirectory()).appending(path: "reqly-icon-\(UUID().uuidString).svg")
        try "<svg xmlns='http://www.w3.org/2000/svg'/>".write(to: image, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: image) }
        let (entries, folder) = try Self.entries([
            "org.gnome.Calculator.desktop": Self.entry(name: "Calculator", icon: "org.gnome.Calculator"),
            "firefox_firefox.desktop": Self.entry(name: "Firefox", icon: image.path)
                + "X-SnapInstanceName=firefox\n",
            "gone.desktop": Self.entry(name: "Gone", icon: "/nowhere/gone.png"),
        ])
        defer { try? FileManager.default.removeItem(at: folder) }

        let calculator = Source(name: "Calculator", bundleID: "org.gnome.Calculator", path: "/usr/bin/gnome-calculator")
        #expect(AppIcon.find(for: calculator, in: entries) == .themed("org.gnome.Calculator"))
        #expect(
            AppIcon.find(for: Source(name: "Firefox", bundleID: "firefox_firefox"), in: entries) == .file(image.path))
        // A snap with no entry of its own name, found by the snap's.
        #expect(AppIcon.find(for: Source(name: "firefox", bundleID: "firefox"), in: entries) == .file(image.path))
        #expect(AppIcon.find(for: Source(name: "Gone", bundleID: "gone"), in: entries) == .generic)
    }

    @Test func fallsBackForToolsAndAppsWithNoEntry() throws {
        let (entries, folder) = try Self.entries([:])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(AppIcon.find(for: Source(name: "curl", path: "/usr/bin/curl"), in: entries) == .generic)
        // A Flatpak's icon is in the theme under its ID, even without its entry.
        #expect(
            AppIcon.find(for: Source(name: "Firefox", bundleID: "org.mozilla.firefox"), in: entries)
                == .themed("org.mozilla.firefox"))
        #expect(AppIcon.find(for: Source(name: "htop", bundleID: "htop"), in: entries) == .generic)
    }
}
