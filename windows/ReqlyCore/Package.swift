// swift-tools-version: 6.2
import PackageDescription

// ReqlyCore.dll: the core, for the Windows app, behind a small C interface that carries JSON
// messages. CoreInterface handles the messages; its tests run on the Mac and Linux too. See
// ReqlyCore.h for the C functions.
//
// WindowsSystem holds what only Windows has, as ReqlyMacKit does for the Mac: your user's proxy
// setting, and which app opened a connection. CCrashStack writes the crashed thread's stack when
// Swift's code stops Reqly, for the crash report.
let package = Package(
    name: "ReqlyCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ReqlyCore", type: .dynamic, targets: ["ReqlyCore"])
    ],
    dependencies: [.package(path: "../../core")],
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
            name: "CoreInterface",
            dependencies: [
                "WindowsSystem",
                .product(name: "BodyKit", package: "core"),
                .product(name: "Capture", package: "core"),
                .product(name: "CertificateAuthority", package: "core"),
                .product(name: "DeviceBridge", package: "core"),
                .product(name: "HAR", package: "core"),
                .product(name: "Presentation", package: "core"),
                .product(name: "ProxyEngine", package: "core"),
                .product(name: "ReqlyModel", package: "core"),
                .product(name: "TrafficStore", package: "core"),
            ]
        ),
        .target(
            name: "ReqlyCore",
            dependencies: [
                "CCrashStack", "CoreInterface", "WindowsSystem", .product(name: "TrafficStore", package: "core"),
            ]),
        .testTarget(
            name: "WindowsSystemTests",
            dependencies: ["WindowsSystem", .product(name: "CertificateAuthority", package: "core")]),
        .testTarget(
            name: "CoreInterfaceTests",
            dependencies: [
                "CoreInterface", "ReqlyCore", "WindowsSystem",
                .product(name: "Capture", package: "core"),
                .product(name: "CertificateAuthority", package: "core"),
                .product(name: "DeviceBridge", package: "core"),
                .product(name: "Presentation", package: "core"),
                .product(name: "ProxyEngine", package: "core"),
                .product(name: "ReqlyModel", package: "core"),
                .product(name: "TrafficStore", package: "core"),
            ]
        ),
    ]
)
