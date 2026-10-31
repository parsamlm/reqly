import LinuxApps
import Testing

@Suite struct SystemdUnitTests {
    private let user = "/user.slice/user-1000.slice/user@1000.service"

    private func unit(_ path: String) -> SystemdUnit {
        SystemdUnit(cgroupPath: path)
    }

    /// The names the desktop VMs showed, on Ubuntu 24.04 and 26.04 and Debian 13.
    @Test func readsTheUnitsDesktopsMakeForApps() {
        let calculator = unit(user + "/app.slice/app-gnome-org.gnome.Calculator-7858.scope")
        #expect(calculator.kind == .app(desktopID: "org.gnome.Calculator"))
        #expect(calculator.pid == 7858)
        #expect(calculator.desktopID == "org.gnome.Calculator")
        // GNOME Shell escapes the dash in Firefox ESR's desktop ID.
        let firefox = unit(user + "/app.slice/app-gnome-firefox\\x2desr-7699.scope")
        #expect(firefox.kind == .app(desktopID: "firefox-esr"))
        #expect(firefox.pid == 7699)
        #expect(firefox.name == "app-gnome-firefox\\x2desr-7699.scope")
        #expect(
            unit(user + "/app.slice/app-gnome-update\\x2dnotifier-2128.scope").kind
                == .app(desktopID: "update-notifier"))
        #expect(
            unit(user + "/app.slice/app-gnome-org.gnome.Evolution\\x2dalarm\\x2dnotify-2100.scope").kind
                == .app(desktopID: "org.gnome.Evolution-alarm-notify"))
        #expect(
            unit(user + "/app.slice/app-gnome-org.gnome.Software-1870.scope").kind
                == .app(desktopID: "org.gnome.Software"))
        // KDE: a service with a random part after @, or a scope with the process's ID.
        let kwrite = unit(user + "/app.slice/app-org.kde.kwrite@0f8a3e5b9c1d4e2f8a7b6c5d4e3f2a1b.service")
        #expect(kwrite.kind == .app(desktopID: "org.kde.kwrite"))
        #expect(kwrite.pid == nil)
        let kcalc = unit(user + "/app.slice/app-org.kde.kcalc-11925.scope")
        #expect(kcalc.kind == .app(desktopID: "org.kde.kcalc"))
        #expect(kcalc.pid == 11925)
        // A scope whose random part is a UUID.
        #expect(
            unit(user + "/app.slice/app-org.kde.dolphin-3b241101-e2bb-4255-8caf-4136c566a962.scope").kind
                == .app(desktopID: "org.kde.dolphin"))
    }

    @Test func readsFlatpaksAndSnaps() {
        let flatpak = unit(user + "/app.slice/app-flatpak-org.mozilla.firefox-4242.scope")
        #expect(flatpak.kind == .flatpak(appID: "org.mozilla.firefox"))
        #expect(flatpak.pid == 4242)
        #expect(flatpak.desktopID == "org.mozilla.firefox")
        let snap = unit(user + "/app.slice/snap.firefox.firefox-e53afeb0-6c09-4570-bfe0-099d25593b6f.scope")
        #expect(snap.kind == .snap(name: "firefox", app: "firefox"))
        #expect(snap.desktopID == "firefox_firefox")
        #expect(
            unit(user + "/app.slice/snap.firefox.firefox-a5d561f8-dd4f-4fc6-96cc-5a35c05e9041.scope").kind
                == .snap(name: "firefox", app: "firefox"))
        // Older snapd, and a snap's service.
        #expect(
            unit(user + "/app.slice/snap.code.code.0123456789abcdef0123456789abcdef.scope").kind
                == .snap(name: "code", app: "code"))
        #expect(unit("/system.slice/snap.lxd.daemon.service").kind == .snap(name: "lxd", app: "daemon"))
        #expect(unit("/system.slice/snap.lxd.daemon.service").desktopID == "lxd_daemon")
    }

    @Test func knowsTheTerminalsUnits() {
        let vte = unit(
            user + "/app.slice/app-org.gnome.Terminal.slice/vte-spawn-8bc8c0cd-ae34-4ed6-b5c9-6d20ddc3f962.scope")
        #expect(vte.kind == .terminal(desktopID: "org.gnome.Terminal"))
        #expect(vte.desktopID == nil)
        // Before VTE moves the shell into its own scope.
        #expect(
            unit(user + "/app.slice/app-org.gnome.Terminal.slice/gnome-terminal-server.service").kind
                == .terminal(desktopID: "org.gnome.Terminal"))
        #expect(
            unit(user + "/app.slice/ptyxis-spawn-97c42b46-774a-42c3-8261-0b3d8140777b.scope").kind
                == .terminal(desktopID: "org.gnome.Ptyxis"))
        // Konsole's shells, and Konsole's own process.
        #expect(
            unit(user + "/app.slice/app-org.kde.konsole@fc3fe4fe6cdd4ae08ae1b29d02b6247a.service").kind
                == .terminal(desktopID: "org.kde.konsole"))
        #expect(
            unit(user + "/app.slice/app-org.kde.konsole-11925.scope").kind == .terminal(desktopID: "org.kde.konsole"))
        // A VTE terminal other than GNOME Terminal, outside an app's slice.
        #expect(
            unit(user + "/app.slice/vte-spawn-1c0755f9-e196-4bbe-b64e-05fbb8bd4b09.scope").kind
                == .terminal(desktopID: nil))
        // A process right in GNOME Terminal's slice.
        #expect(
            unit(user + "/app.slice/app-org.gnome.Terminal.slice").kind == .terminal(desktopID: "org.gnome.Terminal"))
    }

    @Test func knowsUnitsThatDontNameTheApp() {
        #expect(unit(user + "/session.slice/dbus.service").kind == .other)
        #expect(unit("/user.slice/user-1000.slice/session-13.scope").kind == .other)
        #expect(unit("/user.slice/user-1000.slice/session-20.scope").pid == nil)
        #expect(unit(user + "/init.scope").kind == .other)
        #expect(unit("/").kind == .other)
        #expect(unit("").kind == .other)
        // Services, your user's and the system's.
        #expect(unit(user + "/session.slice/gvfs-daemon.service").kind == .service("gvfs-daemon.service"))
        #expect(unit(user + "/app.slice/gnome-keyring-daemon.service").kind == .service("gnome-keyring-daemon.service"))
        #expect(unit(user + "/app.slice/reqly-probe-24006.service").kind == .service("reqly-probe-24006.service"))
        #expect(unit("/system.slice/packagekit.service").kind == .service("packagekit.service"))
        #expect(unit("/system.slice/system-getty.slice/getty@tty1.service").kind == .service("getty@tty1.service"))
    }

    /// Apps Reqly starts itself, as `systemd-run --user` units, and apps D-Bus starts as units
    /// of their own, as dbus-broker does.
    @Test func readsLaunchersUnits() {
        #expect(
            unit(user + "/app.slice/app-reqly-org.gnome.Calculator@4f2a9c.service").kind
                == .app(desktopID: "org.gnome.Calculator"))
        #expect(
            unit(user + "/app.slice/app-reqly-org.gnome.Calculator-4f2a9c1d.service").kind
                == .app(desktopID: "org.gnome.Calculator"))
        #expect(
            unit(user + "/app.slice/app-gnome-org.gnome.Nautilus@autostart.service").kind
                == .app(desktopID: "org.gnome.Nautilus"))
        #expect(
            unit(user + "/app.slice/app-dbus\\x2d:1.2\\x2dorg.gnome.Maps@0.service").kind
                == .app(desktopID: "org.gnome.Maps"))
        #expect(
            unit(user + "/app.slice/dbus-:1.17-org.gnome.Characters@0.service").kind
                == .app(desktopID: "org.gnome.Characters"))
    }

    @Test func unescapes() {
        #expect(SystemdUnit.unescape("firefox\\x2desr") == "firefox-esr")
        #expect(SystemdUnit.unescape("a\\x20b\\x5cc") == "a b\\c")
        #expect(SystemdUnit.unescape("plain") == "plain")
        #expect(SystemdUnit.unescape("broken\\x2") == "broken\\x2")
        #expect(SystemdUnit.unescape("caf\\xc3\\xa9") == "café")
    }
}
