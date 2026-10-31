// swift-tools-version: 6.2
import PackageDescription

// Reqly for Linux: what only Linux has, which the app hands the core as its SystemParts, as
// WindowsSystem does on Windows. The app links the core and CoreInterface directly, in one
// process, with no C interface between them. Build and test it with linux/scripts/app.sh, in
// Ubuntu 24.04's development packages, the oldest Reqly supports.
//
// - CGio, CSecret: GIO (GSettings and D-Bus) and libsecret, the system's own, through pkg-config.
// - CLinux: the little C that Swift can't write cleanly: asking the kernel who owns a socket,
//   waiting for a process to end, and starting one that inherits none of Reqly's descriptors.
// - LinuxDesktop: your desktop's proxy setting, GNOME's and KDE's, the watcher that puts it back,
//   the login entry, and the terminal set up for Reqly.
// - LinuxTrust: where Reqly's certificate is kept and trusted: its key in your keyring or a file,
//   the browsers' NSS databases, Firefox's profiles, and the computer's list, through the helper.
// - LinuxApps: which app opened a connection, this computer's addresses and its neighbors'.
// - LinuxSystem: SystemParts.linux, from the three, and the folders Reqly keeps its files in.
let package = Package(
    name: "ReqlyLinux",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LinuxSystem", targets: ["LinuxSystem"])
    ],
    dependencies: [.package(path: "../core"), .package(path: "../core-interface")],
    targets: [
        .systemLibrary(
            name: "CGio",
            pkgConfig: "gio-2.0",
            providers: [.apt(["libglib2.0-dev"])]
        ),
        .systemLibrary(
            name: "CSecret",
            pkgConfig: "libsecret-1",
            providers: [.apt(["libsecret-1-dev"])]
        ),
        .target(name: "CLinux"),
        .target(
            name: "LinuxDesktop",
            dependencies: ["CGio", "CLinux", .product(name: "ReqlyModel", package: "core")]
        ),
        .target(
            name: "LinuxTrust",
            dependencies: [
                "CGio", "CSecret", "CLinux",
                .product(name: "CertificateAuthority", package: "core"),
                .product(name: "ReqlyModel", package: "core"),
            ]
        ),
        .target(
            name: "LinuxApps",
            dependencies: [
                "CLinux",
                .product(name: "DeviceBridge", package: "core"),
                .product(name: "ReqlyModel", package: "core"),
            ]
        ),
        .target(
            name: "LinuxSystem",
            dependencies: [
                "LinuxDesktop", "LinuxTrust", "LinuxApps",
                .product(name: "CoreInterface", package: "core-interface"),
                .product(name: "CertificateAuthority", package: "core"),
                .product(name: "ReqlyModel", package: "core"),
            ]
        ),
        .testTarget(
            name: "LinuxDesktopTests",
            dependencies: ["LinuxDesktop", "CLinux", .product(name: "ReqlyModel", package: "core")]
        ),
        .testTarget(
            name: "LinuxTrustTests",
            dependencies: [
                "LinuxTrust",
                .product(name: "CertificateAuthority", package: "core"),
                .product(name: "ReqlyModel", package: "core"),
            ]
        ),
        .testTarget(
            name: "LinuxAppsTests",
            dependencies: ["LinuxApps", "CLinux", .product(name: "ReqlyModel", package: "core")]
        ),
        // Sessions with Linux's own parts, through the stand-ins test runs of the app ask for.
        .testTarget(
            name: "LinuxSystemTests",
            dependencies: [
                "LinuxSystem", "LinuxDesktop", "LinuxTrust", "LinuxApps",
                .product(name: "CoreInterface", package: "core-interface"),
                .product(name: "ReqlyModel", package: "core"),
            ]
        ),
    ]
)
