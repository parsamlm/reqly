import Foundation
import Testing

@testable import LinuxApps

@Suite struct DesktopEntriesTests {
    @Test func readsAnEntry() throws {
        let contents = """
            # A comment
            [Desktop Entry]
            Type=Application
            Name=Calculator
            Name[de]=Rechner
            Name[de_DE]=Taschenrechner
            Name[pt_BR]=Calculadora
            Icon=org.gnome.Calculator
            Exec=gnome-calculator %U
            TryExec=gnome-calculator
            StartupWMClass=gnome-calculator
            Categories=GNOME;GTK;Utility;Calculator;
            NoDisplay=false
            Comment=Line one\\nline two\\sand\\\\more

            [Desktop Action new-window]
            Name=New Window
            Exec=gnome-calculator --new-window
            """
        let german = try #require(
            DesktopEntry(
                id: "org.gnome.Calculator", file: "/x.desktop", contents: contents,
                locales: DesktopEntries.variants(of: "de_DE.UTF-8"), searchPath: []))
        #expect(german.name == "Taschenrechner")
        #expect(german.unlocalizedName == "Calculator")
        #expect(german.icon == "org.gnome.Calculator")
        #expect(german.exec == "gnome-calculator %U")
        #expect(german.tryExec == "gnome-calculator")
        #expect(german.startupWMClass == "gnome-calculator")
        #expect(german.categories == ["GNOME", "GTK", "Utility", "Calculator"])
        #expect(!german.noDisplay && !german.hidden && !german.runsInTerminal && !german.isTerminalEmulator)
        // Not on the search path, so it keeps its bare name.
        #expect(german.program == "gnome-calculator")
        let austrian = DesktopEntry(
            id: "a", file: "/a", contents: contents, locales: DesktopEntries.variants(of: "de_AT"), searchPath: [])
        #expect(austrian?.name == "Rechner")
        let english = DesktopEntry(id: "a", file: "/a", contents: contents, locales: ["en_US", "en"], searchPath: [])
        #expect(english?.name == "Calculator")
        // Not applications.
        #expect(
            DesktopEntry(
                id: "l", file: "/l", contents: "[Desktop Entry]\nType=Link\nName=L\nURL=x", locales: [], searchPath: [])
                == nil)
        #expect(
            DesktopEntry(
                id: "n", file: "/n", contents: "[Desktop Entry]\nType=Application\n", locales: [], searchPath: [])
                == nil)
        #expect(
            DesktopEntry(
                id: "g", file: "/g", contents: "[Other]\nType=Application\nName=G", locales: [], searchPath: []) == nil)
        #expect(DesktopEntry.unescape("a\\sb\\nc\\\\d\\;") == "a b\nc\\d\\;")
    }

    @Test func splitsExecLines() {
        #expect(DesktopEntry.arguments(ofExec: "gnome-calculator %U") == ["gnome-calculator"])
        #expect(
            DesktopEntry.arguments(ofExec: #""/opt/My App/run" --name "a \"b\" \$c \\ d" 100%% %f"#)
                == ["/opt/My App/run", "--name", #"a "b" $c \ d"#, "100%"])
        #expect(DesktopEntry.arguments(ofExec: "  code  --new-window\t%F ") == ["code", "--new-window"])
        #expect(DesktopEntry.arguments(ofExec: #"a "" b"#) == ["a", "b"])
        let snap = DesktopEntry.started(
            DesktopEntry.arguments(
                ofExec:
                    "env BAMF_DESKTOP_FILE_HINT=/var/lib/snapd/desktop/applications/firefox_firefox.desktop /snap/bin/firefox %u"
            ))
        #expect(snap.program == "/snap/bin/firefox")
        let flatpak = DesktopEntry.started(
            DesktopEntry.arguments(
                ofExec:
                    "/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=firefox --file-forwarding org.mozilla.firefox @@u %u @@"
            ))
        #expect(flatpak.program == nil)
        #expect(flatpak.flatpak == "org.mozilla.firefox")
        #expect(DesktopEntry.started(["python3", "-O", "/usr/bin/gnome-tweaks"]).program == "/usr/bin/gnome-tweaks")
        #expect(DesktopEntry.started(["java", "-jar", "/opt/tool/tool.jar"]).program == "/opt/tool/tool.jar")
        #expect(DesktopEntry.started(["sh", "-c", "foo | bar"]).program == nil)
        #expect(DesktopEntry.started(["env", "-u", "X", "A=1", "/usr/bin/app"]).program == "/usr/bin/app")
    }

    @Test func knowsYourLanguages() {
        #expect(DesktopEntries.variants(of: "de_DE.UTF-8@euro") == ["de_DE@euro", "de_DE", "de@euro", "de"])
        #expect(DesktopEntries.variants(of: "fa_IR.UTF-8") == ["fa_IR", "fa"])
        #expect(DesktopEntries.variants(of: "sr@latin") == ["sr@latin", "sr"])
        #expect(DesktopEntries.variants(of: "C.UTF-8").isEmpty)
        #expect(DesktopEntries.variants(of: "POSIX").isEmpty)
        #expect(DesktopEntries.currentLocales(environment: ["LANG": "fr_FR.UTF-8"]) == ["fr_FR", "fr"])
        #expect(
            DesktopEntries.currentLocales(environment: [
                "LANGUAGE": "pt_BR:pt", "LC_MESSAGES": "en_GB.UTF-8", "LANG": "x",
            ])
                == ["pt_BR", "pt", "en_GB", "en"])
        #expect(DesktopEntries.currentLocales(environment: ["LC_ALL": "C"]).isEmpty)
    }

    @Test func listsTheStandardFolders() {
        let folders = DesktopEntries.standardFolders(environment: [
            "HOME": "/home/p", "XDG_DATA_DIRS": "/usr/share/ubuntu:/usr/local/share/:/usr/share:/var/lib/snapd/desktop",
        ])
        #expect(
            folders.map(\.path) == [
                "/home/p/.local/share/applications", "/usr/share/ubuntu/applications", "/usr/local/share//applications",
                "/usr/share/applications", "/var/lib/snapd/desktop/applications",
                "/home/p/.local/share/flatpak/exports/share/applications",
                "/var/lib/flatpak/exports/share/applications",
                "/home/p/.config/autostart", "/etc/xdg/autostart",
            ])
        #expect(folders.filter(\.isAutostart).count == 2)
        let plain = DesktopEntries.standardFolders(environment: ["HOME": "/home/p", "XDG_DATA_HOME": "/d"]).map(\.path)
        #expect(plain.prefix(3) == ["/d/applications", "/usr/local/share/applications", "/usr/share/applications"])
    }

    /// A computer's worth of entries: your own, the system's, a snap's, a Flatpak's and an
    /// autostart entry, with programs in the fixture.
    private func computer() throws -> (Fixture, DesktopEntries) {
        let fixture = try Fixture()
        let bin = fixture.path("/usr/bin")
        try fixture.write("/usr/lib/firefox-esr/firefox-esr", "", executable: true)
        try fixture.link("/usr/bin/firefox-esr", to: fixture.path("/usr/lib/firefox-esr/firefox-esr"))
        try fixture.write("/opt/google/chrome/google-chrome", "#!/bin/sh", executable: true)
        try fixture.write("/opt/google/chrome/chrome", "", executable: true)
        try fixture.link("/usr/bin/google-chrome-stable", to: fixture.path("/opt/google/chrome/google-chrome"))
        try fixture.write("/usr/share/code/code", "", executable: true)
        try fixture.write("/usr/share/code/bin/code", "#!/bin/sh", executable: true)
        try fixture.link("/usr/bin/code", to: fixture.path("/usr/share/code/bin/code"))
        try fixture.write("/usr/bin/gnome-calculator", "", executable: true)
        try fixture.write("/usr/bin/htop", "", executable: true)
        try fixture.write("/usr/bin/gnome-tweaks", "#!/usr/bin/python3", executable: true)

        let system = "/usr/share/applications"
        try fixture.write(
            system + "/firefox-esr.desktop",
            """
            [Desktop Entry]
            Type=Application
            Name=Firefox ESR
            Name[fa]=فایرفاکس
            Exec=\(fixture.path("/usr/lib/firefox-esr/firefox-esr")) %u
            Icon=firefox-esr
            StartupWMClass=firefox-esr
            """)
        try fixture.write(
            system + "/google-chrome.desktop",
            """
            [Desktop Entry]
            Type=Application
            Name=Google Chrome
            Exec=\(fixture.path("/usr/bin/google-chrome-stable")) %U
            Icon=google-chrome
            """)
        try fixture.write(
            system + "/code.desktop",
            """
            [Desktop Entry]
            Type=Application
            Name=Visual Studio Code
            Exec=\(fixture.path("/usr/share/code/code")) %F
            Icon=vscode
            StartupWMClass=Code
            """)
        try fixture.write(
            system + "/code-url-handler.desktop",
            """
            [Desktop Entry]
            Type=Application
            Name=Visual Studio Code - URL Handler
            Exec=\(fixture.path("/usr/share/code/code")) --open-url %U
            NoDisplay=true
            """)
        try fixture.write(
            system + "/org.gnome.Calculator.desktop",
            """
            [Desktop Entry]
            Type=Application
            Name=Calculator
            Name[fa]=ماشین‌حساب
            Exec=gnome-calculator
            TryExec=gnome-calculator
            """)
        try fixture.write(
            system + "/htop.desktop",
            """
            [Desktop Entry]
            Type=Application
            Name=Htop
            Exec=htop
            Terminal=true
            """)
        try fixture.write(
            system + "/org.gnome.tweaks.desktop",
            """
            [Desktop Entry]
            Type=Application
            Name=Tweaks
            Exec=gnome-tweaks
            """)
        try fixture.write(
            system + "/org.gnome.Ptyxis.desktop",
            """
            [Desktop Entry]
            Type=Application
            Name=Terminal
            Exec=ptyxis --new-window
            Categories=GNOME;GTK;System;TerminalEmulator;
            """)
        try fixture.write(
            system + "/kde4/kate.desktop",
            """
            [Desktop Entry]
            Type=Application
            Name=Kate
            Exec=kate -b %U
            """)
        try fixture.write(
            system + "/org.gnome.Hidden.desktop",
            """
            [Desktop Entry]
            Type=Application
            Name=Was Here
            Exec=hidden-app
            """)
        // Your own copy hides the system's.
        try fixture.write(
            "/home/.local/share/applications/org.gnome.Hidden.desktop",
            """
            [Desktop Entry]
            Type=Application
            Name=Hidden
            Exec=hidden-app
            Hidden=true
            """)
        try fixture.write(
            "/home/.local/share/applications/org.gnome.Calculator.desktop",
            """
            [Desktop Entry]
            Type=Application
            Name=My Calculator
            Exec=gnome-calculator
            """)
        try fixture.write(
            "/var/lib/snapd/desktop/applications/firefox_firefox.desktop",
            """
            [Desktop Entry]
            Version=1.0
            Name=Firefox Web Browser
            Name[fa]=مرورگر فایرفاکس
            Exec=env BAMF_DESKTOP_FILE_HINT=/var/lib/snapd/desktop/applications/firefox_firefox.desktop /snap/bin/firefox %u
            Icon=/snap/firefox/6789/default256.png
            Type=Application
            X-SnapInstanceName=firefox
            """)
        try fixture.write(
            "/var/lib/snapd/desktop/applications/firefox_geckodriver.desktop",
            """
            [Desktop Entry]
            Name=Gecko Driver
            Exec=/snap/bin/firefox.geckodriver
            Type=Application
            NoDisplay=true
            """)
        try fixture.write(
            "/var/lib/flatpak/exports/share/applications/org.mozilla.Thunderbird.desktop",
            """
            [Desktop Entry]
            Name=Thunderbird
            Exec=/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=thunderbird --file-forwarding org.mozilla.Thunderbird @@u %u @@
            Type=Application
            Icon=org.mozilla.Thunderbird
            X-Flatpak=org.mozilla.Thunderbird
            """)
        try fixture.write(
            "/etc/xdg/autostart/update-notifier.desktop",
            """
            [Desktop Entry]
            Name=Update Notifier
            Exec=update-notifier
            Type=Application
            """)
        let entries = DesktopEntries(
            folders: [
                .init(path: fixture.path("/home/.local/share/applications")), .init(path: fixture.path(system)),
                .init(path: fixture.path("/var/lib/flatpak/exports/share/applications")),
                .init(path: fixture.path("/var/lib/snapd/desktop/applications")),
                .init(path: fixture.path("/etc/xdg/autostart"), isAutostart: true),
            ],
            locales: ["fa_IR", "fa"], searchPath: [bin])
        return (fixture, entries)
    }

    private func process(_ path: String?, _ arguments: [String] = [], name: String? = nil) -> RunningProcess {
        RunningProcess(
            pid: 1, path: path,
            name: name ?? (path ?? arguments.first ?? "").split(separator: "/").last.map(String.init) ?? "",
            arguments: arguments.isEmpty ? [path ?? ""] : arguments)
    }

    @Test func findsEntriesByID() throws {
        let (fixture, entries) = try computer()
        // Your own copy comes first.
        #expect(entries.entry(id: "org.gnome.Calculator")?.name == "My Calculator")
        #expect(entries.entry(id: "firefox-esr")?.name == "فایرفاکس")
        #expect(entries.entry(id: "firefox-esr")?.unlocalizedName == "Firefox ESR")
        #expect(entries.entry(id: "firefox-esr")?.program == fixture.path("/usr/lib/firefox-esr/firefox-esr"))
        #expect(entries.entry(id: "org.gnome.Calculator")?.program == fixture.path("/usr/bin/gnome-calculator"))
        // A subfolder's entry has the folder in its ID.
        #expect(entries.entry(id: "kde4-kate")?.name == "Kate")
        // Hidden in your folder, so gone from the system's too.
        #expect(entries.entry(id: "org.gnome.Hidden") == nil)
        let snap = try #require(entries.entry(id: "firefox_firefox"))
        #expect(snap.name == "مرورگر فایرفاکس")
        #expect(snap.snapName == "firefox")
        #expect(snap.program == "/snap/bin/firefox")
        #expect(entries.entry(id: "firefox_geckodriver")?.snapName == "firefox")
        #expect(entries.entries(ofSnap: "firefox").map(\.id) == ["firefox_firefox", "firefox_geckodriver"])
        let flatpak = try #require(entries.entry(id: "org.mozilla.Thunderbird"))
        #expect(flatpak.flatpakID == "org.mozilla.Thunderbird")
        #expect(flatpak.program == nil)
        #expect(entries.entry(id: "update-notifier")?.name == "Update Notifier")
        #expect(entries.entry(id: "org.gnome.Ptyxis")?.isTerminalEmulator == true)
        #expect(entries.entry(id: "htop")?.runsInTerminal == true)
    }

    @Test func matchesProgramsToEntries() throws {
        let (fixture, entries) = try computer()
        // Its program, as the kernel gives it, with links followed.
        #expect(entries.entry(for: process(fixture.path("/usr/lib/firefox-esr/firefox-esr")))?.id == "firefox-esr")
        #expect(entries.entry(for: process(fixture.path("/usr/bin/gnome-calculator")))?.id == "org.gnome.Calculator")
        // A program in the folder the app's program is installed in, past its link and script.
        #expect(entries.entry(for: process(fixture.path("/opt/google/chrome/chrome")))?.id == "google-chrome")
        #expect(
            entries.entry(for: process(fixture.path("/opt/google/chrome/chrome_crashpad_handler")))?.id
                == "google-chrome")
        // VS Code's own entry, not its hidden URL handler, which runs the same program.
        #expect(entries.entry(for: process(fixture.path("/usr/share/code/code")))?.id == "code")
        // An interpreter's script.
        #expect(
            entries.entry(for: process("/usr/bin/python3.12", ["python3", fixture.path("/usr/bin/gnome-tweaks")]))?.id
                == "org.gnome.tweaks")
        // A snap's program, which runs from the snap's own folder.
        #expect(entries.entry(for: process("/snap/firefox/6789/usr/lib/firefox/firefox"))?.id == "firefox_firefox")
        #expect(
            entries.entry(for: process("/snap/firefox/6789/usr/lib/firefox/geckodriver"))?.id == "firefox_geckodriver")
        // A Flatpak's, known from the process.
        #expect(
            entries.entry(for: process("/app/lib/thunderbird/thunderbird"), flatpakID: "org.mozilla.Thunderbird")?.id
                == "org.mozilla.Thunderbird")
        #expect(entries.entry(for: process("/app/lib/thunderbird/thunderbird")) == nil)
        // By name, when the program is somewhere else.
        #expect(entries.entry(for: process("/home/p/build/kate"))?.id == "kde4-kate")
        // Tools have no entry, and one that runs in a terminal counts as a tool.
        #expect(entries.entry(for: process("/usr/bin/curl")) == nil)
        #expect(entries.entry(for: process(fixture.path("/usr/bin/htop"))) == nil)
        // A hidden process is matched by its arguments.
        #expect(
            entries.entry(for: process(nil, [fixture.path("/usr/bin/gnome-calculator")]))?.id == "org.gnome.Calculator")
        // Autostart entries are found by ID only.
        #expect(entries.entry(for: process("/usr/bin/update-notifier")) == nil)
    }

    @Test func readsAgainWhenAFolderChanges() throws {
        let (fixture, _) = try computer()
        let entries = DesktopEntries(
            folders: [.init(path: fixture.path("/usr/share/applications"))], locales: [], searchPath: [],
            interval: .zero)
        let version = entries.version
        #expect(entries.entry(id: "org.example.New") == nil)
        #expect(entries.version == version)
        try fixture.write(
            "/usr/share/applications/org.example.New.desktop", "[Desktop Entry]\nType=Application\nName=New\nExec=new")
        // A folder's time has whole-second precision on some file systems.
        let folder = fixture.path("/usr/share/applications")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: folder)
        #expect(entries.entry(id: "org.example.New")?.name == "New")
        #expect(entries.version == version + 1)
    }

    @Test func knowsInstallFolders() {
        #expect(DesktopEntries.installFolder(of: "/opt/google/chrome/google-chrome") == "/opt/google/chrome")
        #expect(DesktopEntries.installFolder(of: "/usr/share/code/bin/code") == "/usr/share/code")
        #expect(DesktopEntries.installFolder(of: "/usr/lib/firefox-esr/firefox-esr") == "/usr/lib/firefox-esr")
        #expect(DesktopEntries.installFolder(of: "/usr/bin/gnome-calculator") == nil)
        #expect(DesktopEntries.installFolder(of: "/usr/local/bin/tool") == nil)
        #expect(DesktopEntries.installFolder(of: "/usr/libexec/gnome-terminal-server") == nil)
        #expect(DesktopEntries.installFolder(of: "/usr/lib/x86_64-linux-gnu/helper") == nil)
        #expect(DesktopEntries.installFolder(of: "/var/lib/flatpak/exports/bin/org.mozilla.firefox") == nil)
        #expect(DesktopEntries.installFolder(of: "/bin/sh") == nil)
    }
}
