// swift-tools-version: 6.2

import PackageDescription

// The parts of Reqly that reach the Mac's own services: the helper that sets the proxy, the
// Keychain, the process table, and the tools for simulators and emulators. Each sits behind a
// small interface in ReqlyKit, in core, which the Windows app will share: `SystemProxySwitch` in
// ReqlyModel for the helper, and `RootStore` in CertificateAuthority for the Keychain.
let package = Package(
    name: "ReqlyMacKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SystemProxy", targets: ["SystemProxy"]),
        .library(name: "Keychain", targets: ["Keychain"]),
        .library(name: "HelperCore", targets: ["HelperCore"]),
        .library(name: "SourceResolver", targets: ["SourceResolver"]),
        .library(name: "DeviceTools", targets: ["DeviceTools"]),
    ],
    dependencies: [
        .package(path: "../../core")
    ],
    targets: [
        // Reqly's root certificate in the login keychain, trusted through macOS's trust settings.
        .target(name: "Keychain", dependencies: [.product(name: "CertificateAuthority", package: "core")]),
        .target(name: "HelperProtocol"),
        // It reads the Mac's process table.
        .target(name: "SourceResolver", dependencies: [.product(name: "ReqlyModel", package: "core")]),
        .target(name: "SystemProxy", dependencies: ["HelperProtocol", .product(name: "ReqlyModel", package: "core")]),
        // Simulators through Xcode's simctl, and Android emulators through adb.
        .target(name: "DeviceTools"),
        // Only ReqlyHelper, the privileged helper, uses HelperCore.
        .target(name: "HelperCore", dependencies: ["HelperProtocol"]),

        .testTarget(
            name: "SourceResolverTests",
            dependencies: ["SourceResolver", .product(name: "ReqlyModel", package: "core")]
        ),
        .testTarget(name: "DeviceToolsTests", dependencies: ["DeviceTools"]),
        .testTarget(name: "HelperCoreTests", dependencies: ["HelperCore", "HelperProtocol"]),
    ]
)
