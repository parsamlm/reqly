// swift-tools-version: 6.2
import PackageDescription

// ReqlyCore.dll: the core, for the Windows app, behind a small C interface that carries JSON
// messages. CoreInterface, in core-interface, handles the messages. See ReqlyCore.h for the C
// functions.
//
// WindowsSystem holds what only Windows has, as ReqlyMacKit does for the Mac: your user's proxy
// setting, and which app opened a connection. The C functions hand it to CoreInterface as its
// SystemParts. CCrashStack writes the crashed thread's stack when Swift's code stops Reqly, for
// the crash report.
let package = Package(
    name: "ReqlyCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ReqlyCore", type: .dynamic, targets: ["ReqlyCore"])
    ],
    dependencies: [.package(path: "../../core"), .package(path: "../../core-interface")],
    targets: [
        .target(
            name: "CWinINet",
            linkerSettings: [.linkedLibrary("wininet", .when(platforms: [.windows]))]
        ),
        .target(name: "CCrashStack"),
        .target(
            name: "WindowsSystem",
            dependencies: [
                .product(name: "CertificateAuthority", package: "core"),
                .product(name: "DeviceBridge", package: "core"),
                .product(name: "ReqlyModel", package: "core"),
                .target(name: "CWinINet", condition: .when(platforms: [.windows])),
            ],
            linkerSettings: [
                .linkedLibrary("iphlpapi", .when(platforms: [.windows])),
                .linkedLibrary("shell32", .when(platforms: [.windows])),
                .linkedLibrary("version", .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "ReqlyCore",
            dependencies: [
                "CCrashStack", "WindowsSystem",
                .product(name: "CoreInterface", package: "core-interface"),
                .product(name: "CertificateAuthority", package: "core"),
                .product(name: "ReqlyModel", package: "core"),
                .product(name: "TrafficStore", package: "core"),
            ]),
        .testTarget(
            name: "WindowsSystemTests",
            dependencies: [
                "WindowsSystem",
                .product(name: "CertificateAuthority", package: "core"),
                .product(name: "ReqlyModel", package: "core"),
            ]),
        // The C functions, and the sessions they open with Windows' own parts.
        .testTarget(
            name: "ReqlyCoreTests",
            dependencies: [
                "ReqlyCore", "WindowsSystem",
                .product(name: "CoreInterface", package: "core-interface"),
                .product(name: "Capture", package: "core"),
                .product(name: "CertificateAuthority", package: "core"),
                .product(name: "DeviceBridge", package: "core"),
                .product(name: "ProxyEngine", package: "core"),
                .product(name: "ReqlyModel", package: "core"),
                .product(name: "TrafficStore", package: "core"),
            ]
        ),
    ]
)
