import Foundation
import ReqlyModel
import Testing

@testable import LinuxApps

@Suite struct AppLookupTests {
    private let user = "/user.slice/user-1000.slice/user@1000.service/app.slice"

    /// A made-up computer: a `/proc`, a cgroup tree and desktop entries in a fixture.
    private func lookup(_ fixture: Fixture) throws -> AppLookup {
        try fixture.write("/usr/bin/gnome-calculator", "", executable: true)
        try fixture.write(
            "/usr/share/applications/org.gnome.Calculator.desktop",
            "[Desktop Entry]\nType=Application\nName=Calculator\nExec=gnome-calculator")
        try fixture.write(
            "/usr/share/applications/android-studio.desktop",
            "[Desktop Entry]\nType=Application\nName=Android Studio\nExec=/opt/android-studio/bin/studio")
        let entries = DesktopEntries(
            folders: [.init(path: fixture.path("/usr/share/applications"))], locales: [],
            searchPath: [fixture.path("/usr/bin")])
        return AppLookup(
            entries: entries, cgroups: CgroupIndex(root: fixture.path("cgroup"), interval: .zero),
            proc: fixture.path("proc"))
    }

    private func owner(_ inode: UInt64, cgroup: UInt64?) -> SocketOwner {
        SocketOwner(uid: getuid(), inode: inode, cgroupID: cgroup)
    }

    @Test func findsTheAppFromItsUnitAndProcess() throws {
        let fixture = try Fixture()
        let lookup = try lookup(fixture)
        let calculator = try fixture.cgroup(user + "/app-gnome-org.gnome.Calculator-100.scope", processes: [100, 101])
        try fixture.process(100, program: fixture.path("/usr/bin/gnome-calculator"), arguments: ["gnome-calculator"])
        try fixture.process(
            101, program: fixture.path("/usr/bin/gnome-calculator"), arguments: ["gnome-calculator"], sockets: [5001])
        let expected = Source(
            name: "Calculator", bundleID: "org.gnome.Calculator", path: fixture.path("/usr/bin/gnome-calculator"))
        #expect(lookup.origin(of: owner(5001, cgroup: calculator)) == Origin(source: expected))
        // Again, from what it found the first time.
        #expect(lookup.origin(of: owner(5001, cgroup: calculator)) == Origin(source: expected))
        // A socket no process has any more, in the app's unit, is still the app's.
        #expect(lookup.origin(of: owner(5999, cgroup: calculator)) == Origin(source: expected))
    }

    @Test func creditsATerminalsCommand() throws {
        let fixture = try Fixture()
        let lookup = try lookup(fixture)
        let vte = try fixture.cgroup(
            user + "/app-org.gnome.Terminal.slice/vte-spawn-9a7e2a23-1d3f-480b-99d3-4aed76c39d2b.scope",
            processes: [300, 301])
        try fixture.process(300, program: "/usr/bin/bash", arguments: ["bash"])
        try fixture.process(
            301, program: "/usr/bin/curl", arguments: ["curl", "-x", "http://127.0.0.1:9090", "https://example.com"],
            sockets: [7001])
        #expect(
            lookup.origin(of: owner(7001, cgroup: vte)) == Origin(source: Source(name: "curl", path: "/usr/bin/curl")))
        // Made as the window opened, in the terminal's own unit, by a process that has moved since.
        let server = try fixture.cgroup(
            user + "/app-org.gnome.Terminal.slice/gnome-terminal-server.service", processes: [400])
        try fixture.process(
            400, program: "/usr/libexec/gnome-terminal-server", arguments: ["/usr/libexec/gnome-terminal-server"])
        try fixture.process(401, program: "/usr/bin/wget", arguments: ["wget", "example.com"], sockets: [7002])
        #expect(
            lookup.origin(of: owner(7002, cgroup: server))
                == Origin(source: Source(name: "wget", path: "/usr/bin/wget")))
        // With no cgroup, every process is looked through.
        #expect(
            lookup.origin(of: owner(7002, cgroup: nil)) == Origin(source: Source(name: "wget", path: "/usr/bin/wget")))
    }

    /// An emulator started from Android Studio is in Android Studio's unit, and is the emulator.
    @Test func knowsAnEmulatorInAndroidStudiosUnit() throws {
        let fixture = try Fixture()
        let lookup = try lookup(fixture)
        let studio = try fixture.cgroup(user + "/app-gnome-android\\x2dstudio-200.scope", processes: [200, 201, 202])
        try fixture.process(
            200, program: "/opt/android-studio/jbr/bin/java",
            arguments: ["/opt/android-studio/jbr/bin/java", "-Xmx2g"], sockets: [8000])
        let qemu = "/home/p/Android/Sdk/emulator/qemu/linux-x86_64/qemu-system-x86_64"
        try fixture.process(
            201, program: qemu, arguments: [qemu, "-netdelay", "none", "-avd", "Pixel_10_Pro"], sockets: [8001])
        try fixture.process(
            202, program: "/home/p/Android/Sdk/emulator/netsimd", arguments: ["netsimd"], sockets: [8002])
        #expect(
            lookup.origin(of: owner(8001, cgroup: studio))
                == Origin(device: Device(id: "emulator:Pixel_10_Pro", kind: .emulator, name: "Pixel 10 Pro")))
        #expect(lookup.origin(of: owner(8002, cgroup: studio))?.device?.id == "emulator:Pixel_10_Pro")
        #expect(
            lookup.origin(of: owner(8000, cgroup: studio))
                == Origin(
                    source: Source(
                        name: "Android Studio", bundleID: "android-studio", path: "/opt/android-studio/bin/studio")))
    }

    @Test func namesAServiceWhoseProcessIsGone() throws {
        let fixture = try Fixture()
        let lookup = try lookup(fixture)
        let packagekit = try fixture.cgroup("/system.slice/packagekit.service", processes: [900])
        // Another user's: the tests run as root.
        let other = SocketOwner(uid: getuid() == 1 ? 2 : 1, inode: 9001, cgroupID: packagekit)
        #expect(lookup.origin(of: other) == Origin(source: Source(name: "packagekit.service")))
        // An ID no cgroup has.
        #expect(lookup.origin(of: owner(9002, cgroup: 1)) == nil)
    }

    /// A quick command `systemd-run` ran as your own service, gone by the time Reqly asks, isn't
    /// credited to the made-up name of its unit.
    @Test func namesNothingForYourOwnServiceWhoseProcessIsGone() throws {
        let fixture = try Fixture()
        let lookup = try lookup(fixture)
        let unit = try fixture.cgroup(user + "/run-p12651-i12951.service", processes: [])
        #expect(lookup.origin(of: owner(9101, cgroup: unit)) == nil)
        // While its process is there, it's credited to the program.
        let curl = try fixture.cgroup(user + "/run-p12652-i12952.service", processes: [910])
        try fixture.process(910, program: "/usr/bin/curl", arguments: ["curl", "example.com"], sockets: [9102])
        #expect(
            lookup.origin(of: owner(9102, cgroup: curl)) == Origin(source: Source(name: "curl", path: "/usr/bin/curl")))
    }

    /// A process that hides its open files may hold a socket only when it's the socket's user's:
    /// GDM's root session worker, in a login's session scope, never holds an app's.
    @Test func countsOnlyTheSocketUsersHiddenProcesses() throws {
        let fixture = try Fixture()
        try fixture.write("proc/700/status", "Name:\tgdm-session-wor\nUid:\t0\t0\t0\t0\nGid:\t0\t0\t0\t0\n")
        try fixture.write("proc/701/status", "Name:\tssh-agent\nUid:\t1000\t1000\t1000\t1000\nGid:\t1000\n")
        #expect(Processes.uid(of: 700, in: fixture.path("proc")) == 0)
        #expect(Processes.uid(of: 701, in: fixture.path("proc")) == 1000)
        #expect(Processes.uid(of: 702, in: fixture.path("proc")) == nil)
        #expect(AppLookup.mayHold([700, 701, 702], uid: 1000, in: fixture.path("proc")) == [701])
        #expect(AppLookup.mayHold([700], uid: 1000, in: fixture.path("proc")).isEmpty)
    }

    @Test func walksCgroups() throws {
        let fixture = try Fixture()
        let index = CgroupIndex(root: fixture.path("cgroup"), interval: .seconds(60))
        let scope = try fixture.cgroup(user + "/app-gnome-org.gnome.Calculator-100.scope", processes: [100, 101])
        #expect(index.path(of: scope, uid: 1000) == user + "/app-gnome-org.gnome.Calculator-100.scope")
        #expect(index.processes(in: user + "/app-gnome-org.gnome.Calculator-100.scope") == [100, 101])
        #expect(index.path(of: fixture.inode("cgroup"), uid: 1000) == "/")
        // A cgroup made since: the folders were walked a moment ago, so it waits.
        let later = try fixture.cgroup("/system.slice/later.service", processes: [])
        #expect(index.path(of: later, uid: 0) == nil)
        let eager = CgroupIndex(root: fixture.path("cgroup"), interval: .zero)
        #expect(eager.path(of: later, uid: 0) == "/system.slice/later.service")
    }

    @Test func readsProcesses() throws {
        let fixture = try Fixture()
        try fixture.process(
            42, program: "/usr/bin/python3.12 (deleted)", arguments: ["python3", "-u", "/home/p/serve.py"],
            sockets: [11, 12],
            started: 98765, comm: "python3")
        let proc = fixture.path("proc")
        let process = try #require(Processes.read(42, in: proc))
        #expect(process.path == "/usr/bin/python3.12")
        #expect(process.name == "python3")
        #expect(process.arguments == ["python3", "-u", "/home/p/serve.py"])
        #expect(process.programs == ["/usr/bin/python3.12", "/home/p/serve.py"])
        #expect(Processes.startTime(of: 42, in: proc) == 98765)
        #expect(Processes.holder(ofSocket: 12, among: [7, 42], in: proc).pid == 42)
        #expect(Processes.holder(ofSocket: 13, among: [42], in: proc).pid == nil)
        #expect(Processes.all(in: proc) == [42])
        #expect(Processes.read(43, in: proc) == nil)
        try fixture.write("proc/44/root/.flatpak-info", "[Application]\nname=org.mozilla.firefox\nruntime=runtime/x\n")
        #expect(Processes.flatpakID(of: 44, in: proc) == "org.mozilla.firefox")
    }

    @Test func namesProcessesAsPsDoes() {
        #expect(Processes.name(comm: "curl", path: "/usr/bin/curl", arguments: ["curl"]) == "curl")
        #expect(
            Processes.name(comm: "python3", path: "/usr/bin/python3.12", arguments: ["python3", "x.py"]) == "python3")
        // comm holds 15 characters.
        #expect(
            Processes.name(comm: "gnome-terminal-", path: "/usr/libexec/gnome-terminal-server", arguments: [])
                == "gnome-terminal-server")
        // A process that renamed itself, as Firefox's socket process does.
        #expect(
            Processes.name(
                comm: "Socket Process", path: "/usr/lib/firefox/firefox",
                arguments: ["/usr/lib/firefox/firefox", "-contentproc"])
                == "firefox")
        #expect(Processes.name(comm: "ssh-agent", path: nil, arguments: ["/usr/bin/ssh-agent", "-D"]) == "ssh-agent")
        #expect(Processes.name(comm: "kworker", path: nil, arguments: []) == "kworker")
    }

    /// The whole lookup, for a connection this process opens to itself.
    @Test func findsThisProcessFromItsConnection() throws {
        let (server, client, accepted, proxyPort, clientPort) = try Loopback.connect(.ipv4)
        defer { [server, client, accepted].forEach { close($0) } }
        let lookup = AppLookup(entries: DesktopEntries(folders: [], locales: [], searchPath: []))
        let program = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        let origin = try #require(lookup.origin(clientPort: clientPort, proxyPort: proxyPort))
        #expect(origin.device == nil)
        #expect(origin.source?.path == program)
        #expect(origin.source?.bundleID == nil)
        // Again, while the connection is open.
        #expect(lookup.origin(clientPort: clientPort, proxyPort: proxyPort) == origin)
        // Fast once warm: well under a millisecond each, so a hundred take well under a second
        // even on a busy computer.
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<100 {
                _ = lookup.origin(clientPort: clientPort, proxyPort: proxyPort)
            }
        }
        #expect(elapsed < .milliseconds(500))
        // A lookup that isn't cached: the kernel, the cgroup and the process each time.
        let owner = try #require(SocketOwner.ofConnection(clientPort: clientPort, proxyPort: proxyPort))
        let fresh = AppLookup(entries: DesktopEntries(folders: [], locales: [], searchPath: []))
        _ = fresh.origin(of: owner)
        let uncached = clock.measure {
            for _ in 0..<20 {
                _ = AppLookup(entries: DesktopEntries(folders: [], locales: [], searchPath: []), cgroups: fresh.cgroups)
                    .origin(of: owner)
            }
        }
        #expect(uncached < .milliseconds(400))
    }
}
