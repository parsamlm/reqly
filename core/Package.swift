// swift-tools-version: 6.2

import PackageDescription

// ReqlyKit holds everything in Reqly that isn't UI. See ARCHITECTURE.md for the code map:
// each module only uses the modules below it.
//
// It builds on the Mac, Linux and, later, Windows: the model, the engine, certificates, rules,
// scripts, storage and file formats. The modules that reach the Mac's own services, such as the
// Keychain and the helper, are in mac/ReqlyMacKit.

let products: [Product] = [
    .library(name: "ReqlyModel", targets: ["ReqlyModel"]),
    .library(name: "ProxyEngine", targets: ["ProxyEngine"]),
    .library(name: "Capture", targets: ["Capture"]),
    .library(name: "CertificateAuthority", targets: ["CertificateAuthority"]),
    .library(name: "BodyKit", targets: ["BodyKit"]),
    .library(name: "TrafficStore", targets: ["TrafficStore"]),
    .library(name: "HAR", targets: ["HAR"]),
    .library(name: "Scripts", targets: ["Scripts"]),
]

let targets: [Target] = [
    .target(name: "ReqlyModel"),
    .target(
        name: "CertificateAuthority",
        dependencies: [
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]
    ),
    .target(
        name: "ProxyEngine",
        dependencies: [
            "ReqlyModel",
            "BodyKit",
            "CertificateAuthority",
            "Scripts",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "NIOHTTP2", package: "swift-nio-http2"),
            // To read client certificates' names and dates.
            .product(name: "X509", package: "swift-certificates"),
        ]
    ),
    // zlib, for gzip and deflate. The Mac has it, and Linux has it as a package.
    .systemLibrary(name: "CZlib", providers: [.apt(["zlib1g-dev"]), .yum(["zlib-devel"])]),
    .target(name: "BodyKit", dependencies: ["CZlib"]),
    // QuickJS-ng, the JavaScript engine scripts run in, built from its amalgamation without
    // its standard library, so scripts can't reach files, processes or the network.
    .target(
        name: "CQuickJS",
        exclude: ["LICENSE", "README.md"],
        // Its code is QuickJS-ng's, unchanged, so its warnings aren't Reqly's to fix.
        cSettings: [.unsafeFlags(["-w"])]
    ),
    .target(name: "Scripts", dependencies: ["CQuickJS", "ReqlyModel"]),
    .target(
        name: "TrafficStore",
        dependencies: ["ReqlyModel", "BodyKit", .product(name: "GRDB", package: "GRDB.swift")]
    ),
    .target(name: "HAR", dependencies: ["ReqlyModel", "BodyKit"]),
    .target(
        name: "Capture",
        dependencies: ["ReqlyModel", "ProxyEngine", "CertificateAuthority", "TrafficStore", "Scripts", "BodyKit"]
    ),

    .testTarget(name: "ReqlyModelTests", dependencies: ["ReqlyModel"]),
    .testTarget(name: "ScriptsTests", dependencies: ["Scripts", "ReqlyModel"]),
    .testTarget(
        name: "ProxyEngineTests",
        dependencies: [
            "ProxyEngine",
            "ReqlyModel",
            "CertificateAuthority",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "NIOHTTP2", package: "swift-nio-http2"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]
    ),
    .testTarget(name: "CaptureTests", dependencies: ["Capture", "ProxyEngine", "ReqlyModel", "TrafficStore"]),
    .testTarget(
        name: "TrafficStoreTests",
        dependencies: ["TrafficStore", "ReqlyModel", "BodyKit", .product(name: "GRDB", package: "GRDB.swift")]
    ),
    .testTarget(name: "BodyKitTests", dependencies: ["BodyKit", "CZlib"]),
    .testTarget(name: "HARTests", dependencies: ["HAR", "ReqlyModel"]),
    .testTarget(
        name: "CertificateAuthorityTests",
        dependencies: ["CertificateAuthority", .product(name: "X509", package: "swift-certificates")]
    ),
]

let package = Package(
    name: "ReqlyKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.103.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.46.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    ],
    targets: targets
)
