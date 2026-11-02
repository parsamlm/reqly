import Foundation
import ReqlyModel
import Testing

@testable import LinuxApps

@Suite struct CreditingTests {
    private let user = "/user.slice/user-1000.slice/user@1000.service/app.slice"

    /// Desktop entries for the apps in these tests, with their programs in the fixture.
    private func entries(_ fixture: Fixture) throws -> DesktopEntries {
        try fixture.write("/usr/share/code/code", "", executable: true)
        try fixture.write("/usr/bin/gnome-calculator", "", executable: true)
        try fixture.write("/usr/bin/gnome-tweaks", "", executable: true)
        try fixture.write("/usr/bin/curl", "", executable: true)
        try fixture.write("/usr/bin/git", "", executable: true)
        let applications = "/usr/share/applications"
        try fixture.write(
            applications + "/code.desktop",
            "[Desktop Entry]\nType=Application\nName=Visual Studio Code\nExec=\(fixture.path("/usr/share/code/code")) %F"
        )
        try fixture.write(
            applications + "/org.gnome.Calculator.desktop",
            "[Desktop Entry]\nType=Application\nName=Calculator\nExec=gnome-calculator")
        try fixture.write(
            applications + "/org.gnome.tweaks.desktop",
            "[Desktop Entry]\nType=Application\nName=Tweaks\nExec=gnome-tweaks")
        try fixture.write(
            applications + "/org.gnome.Terminal.desktop",
            "[Desktop Entry]\nType=Application\nName=Terminal\nExec=gnome-terminal\nCategories=GNOME;GTK;System;TerminalEmulator;"
        )
        try fixture.write(
            applications + "/org.mozilla.Thunderbird.desktop",
            "[Desktop Entry]\nType=Application\nName=Thunderbird\nExec=/usr/bin/flatpak run org.mozilla.Thunderbird\nX-Flatpak=org.mozilla.Thunderbird"
        )
        try fixture.write(
            applications + "/firefox_firefox.desktop",
            "[Desktop Entry]\nType=Application\nName=Firefox Web Browser\nExec=/snap/bin/firefox %u\nX-SnapInstanceName=firefox"
        )
        return DesktopEntries(
            folders: [.init(path: fixture.path(applications))], locales: [], searchPath: [fixture.path("/usr/bin")])
    }

    private func process(_ path: String?, _ arguments: [String]? = nil, pid: Int32 = 10) -> RunningProcess {
        RunningProcess(
            pid: pid, path: path, name: path.map { String($0.split(separator: "/").last ?? "") } ?? "?",
            arguments: arguments ?? [path ?? ""])
    }

    /// What comes from Reqly's own unit is what Reqly started, such as the shell of a terminal
    /// that stayed in it, so each program is itself, even one outside a `bin` folder.
    @Test func creditsWhatReqlysUnitHoldsToItself() throws {
        let fixture = try Fixture()
        let entries = try entries(fixture)
        let helper = "/usr/lib/git-core/git-remote-http"
        let unit = SystemdUnit(cgroupPath: user + "/app-net.reqly.Reqly@3f2a9c41b7d84e1f9d3c2b1a0e9f8d7c.service")
        #expect(unit.desktopID == "net.reqly.Reqly")
        let source = Crediting.source(
            unit: unit, process: process(helper, [helper, "origin", "http://example.com/x.git"]),
            leader: "/home/you/.local/bin/reqly", entries: entries)
        #expect(source == Source(name: "git-remote-http", path: helper))
    }

    @Test func creditsATerminalsCommandToItself() throws {
        let fixture = try Fixture()
        let entries = try entries(fixture)
        let curl = process(fixture.path("/usr/bin/curl"), ["curl", "https://example.com"])
        for path in [
            user + "/app-org.gnome.Terminal.slice/vte-spawn-9a7e2a23-1d3f-480b-99d3-4aed76c39d2b.scope",
            user + "/app-org.gnome.Terminal.slice/gnome-terminal-server.service",
            user + "/ptyxis-spawn-97c42b46-774a-42c3-8261-0b3d8140777b.scope",
            user + "/app-org.kde.konsole@fc3fe4fe6cdd4ae08ae1b29d02b6247a.service",
            "/user.slice/user-1000.slice/session-20.scope",
        ] {
            let source = Crediting.source(
                unit: SystemdUnit(cgroupPath: path), process: curl, leader: "/usr/bin/bash", entries: entries)
            #expect(source == Source(name: "curl", path: fixture.path("/usr/bin/curl")), "\(path)")
        }
        // An app started from a terminal is the app.
        let calculator = Crediting.source(
            unit: SystemdUnit(cgroupPath: user + "/ptyxis-spawn-97c42b46-774a-42c3-8261-0b3d8140777b.scope"),
            process: process(fixture.path("/usr/bin/gnome-calculator")), leader: nil, entries: entries)
        #expect(
            calculator
                == Source(
                    name: "Calculator", bundleID: "org.gnome.Calculator",
                    path: fixture.path("/usr/bin/gnome-calculator")))
        // A terminal unit whose command hides itself names nothing.
        #expect(
            Crediting.source(
                unit: SystemdUnit(
                    cgroupPath: user
                        + "/app-org.gnome.Terminal.slice/vte-spawn-9a7e2a23-1d3f-480b-99d3-4aed76c39d2b.scope"),
                process: nil, leader: nil, entries: entries) == nil)
        // A terminal known only by its entry's category.
        let terminalApp = SystemdUnit(
            name: "app-gnome-org.gnome.Terminal-5.scope", kind: .app(desktopID: "org.gnome.Terminal"))
        #expect(
            Crediting.source(unit: terminalApp, process: curl, leader: nil, entries: entries)
                == Source(name: "curl", path: fixture.path("/usr/bin/curl")))
    }

    @Test func creditsAnAppsProcessesToTheApp() throws {
        let fixture = try Fixture()
        let entries = try entries(fixture)
        let code = SystemdUnit(cgroupPath: user + "/app-gnome-code-4000.scope")
        let vscode = Source(name: "Visual Studio Code", bundleID: "code", path: fixture.path("/usr/share/code/code"))
        let leader = fixture.path("/usr/share/code/code")
        // Its program, and a helper in its folder, are the app.
        #expect(Crediting.source(unit: code, process: process(leader), leader: leader, entries: entries) == vscode)
        #expect(
            Crediting.source(
                unit: code, process: process(fixture.path("/usr/share/code/chrome_crashpad_handler")), leader: leader,
                entries: entries) == vscode)
        // A tool it started, such as git, counts as itself.
        #expect(
            Crediting.source(
                unit: code, process: process(fixture.path("/usr/bin/git")), leader: leader, entries: entries)
                == Source(name: "git", path: fixture.path("/usr/bin/git")))
        // A process that hides itself, in the app's unit, is the app.
        #expect(Crediting.source(unit: code, process: process(nil), leader: leader, entries: entries) == vscode)
        #expect(Crediting.source(unit: code, process: nil, leader: nil, entries: entries) == vscode)
        // An app run by an interpreter: the unit's first process is python3, and so is the
        // process with the socket.
        let tweaks = SystemdUnit(cgroupPath: user + "/app-gnome-org.gnome.tweaks-4100.scope")
        let python = process("/usr/bin/python3.12", ["python3", fixture.path("/usr/bin/gnome-tweaks")])
        #expect(
            Crediting.source(unit: tweaks, process: python, leader: "/usr/bin/python3.12", entries: entries)
                == Source(name: "Tweaks", bundleID: "org.gnome.tweaks", path: fixture.path("/usr/bin/gnome-tweaks")))
    }

    @Test func creditsSnapsAndFlatpaks() throws {
        let fixture = try Fixture()
        let entries = try entries(fixture)
        let snap = SystemdUnit(cgroupPath: user + "/snap.firefox.firefox-e53afeb0-6c09-4570-bfe0-099d25593b6f.scope")
        let firefox = Source(name: "Firefox Web Browser", bundleID: "firefox_firefox", path: "/snap/bin/firefox")
        #expect(
            Crediting.source(
                unit: snap, process: process("/snap/firefox/6789/usr/lib/firefox/firefox"),
                leader: "/snap/firefox/6789/usr/lib/firefox/firefox", entries: entries) == firefox)
        // A snap's helper with a program in its own bin folder is still the snap.
        #expect(
            Crediting.source(
                unit: snap, process: process("/snap/firefox/6789/usr/bin/helper"),
                leader: "/snap/firefox/6789/usr/lib/firefox/firefox", entries: entries) == firefox)
        // A snap with no desktop entry.
        let other = SystemdUnit(cgroupPath: user + "/snap.tool.serve-e53afeb0-6c09-4570-bfe0-099d25593b6f.scope")
        #expect(
            Crediting.source(unit: other, process: process("/snap/tool/1/bin/serve"), leader: nil, entries: entries)
                == Source(name: "tool serve", bundleID: "tool_serve", path: "/snap/tool/1/bin/serve"))
        let flatpak = SystemdUnit(cgroupPath: user + "/app-flatpak-org.mozilla.Thunderbird-777.scope")
        let thunderbird = process("/app/lib/thunderbird/thunderbird")
        #expect(
            Crediting.source(unit: flatpak, process: thunderbird, leader: thunderbird.path, entries: entries)
                == Source(name: "Thunderbird", bundleID: "org.mozilla.Thunderbird", path: thunderbird.path))
        #expect(
            Crediting.source(
                unit: flatpak, process: process("/app/bin/thunderbird-helper"), leader: thunderbird.path,
                entries: entries)
                == Source(name: "Thunderbird", bundleID: "org.mozilla.Thunderbird", path: thunderbird.path))
        // A Flatpak run from a terminal, found by the process's .flatpak-info.
        #expect(
            Crediting.source(
                unit: SystemdUnit(cgroupPath: "/user.slice/user-1000.slice/session-4.scope"), process: thunderbird,
                leader: nil, entries: entries, flatpakID: "org.mozilla.Thunderbird")?.bundleID
                == "org.mozilla.Thunderbird")
    }

    @Test func namesAppsWithoutEntriesAndServices() throws {
        let fixture = try Fixture()
        let entries = try entries(fixture)
        // An app whose entry Reqly can't find is named from its ID.
        #expect(
            Crediting.source(
                unit: SystemdUnit(cgroupPath: user + "/app-gnome-org.gnome.Maps-900.scope"),
                process: process("/usr/bin/gnome-maps"),
                leader: "/usr/bin/gnome-maps", entries: entries)
                == Source(name: "Maps", bundleID: "org.gnome.Maps", path: "/usr/bin/gnome-maps"))
        #expect(
            Crediting.source(
                unit: SystemdUnit(cgroupPath: user + "/app-gnome-firefox\\x2desr-7699.scope"), process: nil,
                leader: nil,
                entries: entries) == Source(name: "firefox-esr", bundleID: "firefox-esr"))
        // An app D-Bus started, in dbus.service, is known by its process.
        #expect(
            Crediting.source(
                unit: SystemdUnit(
                    cgroupPath: user.replacingOccurrences(of: "app.slice", with: "session.slice/dbus.service")),
                process: process(fixture.path("/usr/bin/gnome-calculator")), leader: "/usr/bin/dbus-daemon",
                entries: entries)?
                .bundleID == "org.gnome.Calculator")
        #expect(
            Crediting.source(
                unit: SystemdUnit(cgroupPath: "/user.slice/user-1000.slice/session-3.scope"), process: nil, leader: nil,
                entries: entries) == nil)
        // Another user's service hides its process; its unit names it.
        let packagekit = SystemdUnit(cgroupPath: "/system.slice/packagekit.service")
        #expect(
            Crediting.source(unit: packagekit, process: nil, leader: nil, entries: entries)
                == Source(name: "packagekit.service"))
        #expect(
            Crediting.source(
                unit: packagekit, process: process("/usr/libexec/packagekitd"), leader: nil, entries: entries)
                == Source(name: "packagekitd", path: "/usr/libexec/packagekitd"))
    }

    @Test func toldToolsFromHelpers() {
        let unit = SystemdUnit(name: "app-gnome-x-1.scope", kind: .app(desktopID: "x"))
        func tool(_ path: String, leader: String? = "/opt/x/x") -> Bool {
            Crediting.countsAsItself(
                RunningProcess(pid: 2, path: path, name: "n", arguments: [path]), in: unit, entry: nil, leader: leader)
        }
        #expect(tool("/usr/bin/git"))
        #expect(tool("/usr/local/bin/node"))
        #expect(tool("/home/p/.local/bin/uv"))
        #expect(tool("/usr/sbin/ip"))
        #expect(!tool("/opt/x/helper"))
        #expect(!tool("/usr/lib/x/x-helper"))
        #expect(!tool("/usr/bin/python3.12", leader: "/usr/bin/python3.12"))
    }

    /// The emulator's processes, as Android Studio's SDK lays them out on Linux.
    @Test func knowsAndroidEmulators() {
        let sdk = "/home/p/Android/Sdk/emulator"
        let qemu = RunningProcess(
            pid: 5, path: sdk + "/qemu/linux-x86_64/qemu-system-x86_64", name: "qemu-system-x86_64",
            arguments: [sdk + "/qemu/linux-x86_64/qemu-system-x86_64", "-netdelay", "none", "-avd", "Pixel_10_Pro"])
        #expect(
            Crediting.device(of: qemu, emulators: { [] })
                == Device(id: "emulator:Pixel_10_Pro", kind: .emulator, name: "Pixel 10 Pro"))
        // The emulator on arm64 Linux, started as @name.
        let arm = RunningProcess(
            pid: 6, path: sdk + "/qemu/linux-aarch64/qemu-system-aarch64", name: "qemu-system-aarch64",
            arguments: ["qemu-system-aarch64", "@Pixel_9"])
        #expect(Crediting.device(of: arm, emulators: { [] })?.id == "emulator:Pixel_9")
        // A hidden emulator, known by its arguments.
        let hidden = RunningProcess(pid: 7, path: nil, name: "qemu-system-x86", arguments: qemu.arguments)
        #expect(Crediting.device(of: hidden, emulators: { [] })?.name == "Pixel 10 Pro")
        // A virtual machine's qemu, as GNOME Boxes runs it, isn't Android's.
        let boxes = RunningProcess(
            pid: 8, path: "/usr/bin/qemu-system-x86_64", name: "qemu-system-x86_64",
            arguments: ["/usr/bin/qemu-system-x86_64", "-name", "guest=fedora", "-machine", "q35"])
        #expect(Crediting.device(of: boxes, emulators: { [] }) == nil)
        // netsimd is an emulator's while just one runs.
        let netsim = RunningProcess(pid: 9, path: sdk + "/netsimd", name: "netsimd", arguments: [sdk + "/netsimd"])
        #expect(Crediting.device(of: netsim, emulators: { [qemu.arguments] })?.id == "emulator:Pixel_10_Pro")
        #expect(
            Crediting.device(of: netsim, emulators: { [qemu.arguments, arm.arguments] })?.id
                == "emulator:Android Emulator")
        let studio = RunningProcess(
            pid: 10, path: "/opt/android-studio/jbr/bin/java", name: "java", arguments: ["java"])
        #expect(Crediting.device(of: studio, emulators: { [] }) == nil)
    }
}
