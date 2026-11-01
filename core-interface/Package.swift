// swift-tools-version: 6.2
import PackageDescription

// CoreInterface: the core as the apps that aren't the Mac's use it. SessionHost answers JSON
// messages and keeps the request list, and its neighbors keep rules, connections, devices,
// Protobuf files and HTTPS, the same way on every system. The Windows app reaches it through
// windows/ReqlyCore's C functions, and the Linux app will link it directly.
//
// What only one system has, such as its proxy setting and certificate store, comes from the app
// as SystemParts when a session opens: WindowsSystem's on Windows. Its tests run on the Mac and
// Linux too.
let package = Package(
    name: "CoreInterface",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoreInterface", targets: ["CoreInterface"])
    ],
    dependencies: [.package(path: "../core")],
    targets: [
        .target(
            name: "CoreInterface",
            dependencies: [
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
        .testTarget(
            name: "CoreInterfaceTests",
            dependencies: [
                "CoreInterface",
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
