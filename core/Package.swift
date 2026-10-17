// swift-tools-version: 6.2

import PackageDescription

// ReqlyKit holds everything in Reqly that isn't UI. See ARCHITECTURE.md for the code map:
// each module only uses the modules below it.
//
// It builds on the Mac, Linux and, later, Windows: the model, the engine, certificates, rules,
// scripts, storage and file formats. The modules that reach the Mac's own services, such as the
// Keychain and the helper, are in mac/ReqlyMacKit.

/// The platforms with a zlib of their own to build against. Windows has none, so it builds zlib
/// from source, in CZlibBundled.
let zlibSystems: [Platform] = [.macOS, .iOS, .linux, .android]

/// The platforms without Apple's Compression framework, which unpacks Brotli on the Mac. They build
/// Brotli's decoder from source, in CBrotliBundled.
let brotliBuilders: [Platform] = [.windows, .linux]

let products: [Product] = [
    .library(name: "ReqlyModel", targets: ["ReqlyModel"]),
    .library(name: "ProxyEngine", targets: ["ProxyEngine"]),
    .library(name: "Capture", targets: ["Capture"]),
    .library(name: "CertificateAuthority", targets: ["CertificateAuthority"]),
    .library(name: "BodyKit", targets: ["BodyKit"]),
    .library(name: "TrafficStore", targets: ["TrafficStore"]),
    .library(name: "HAR", targets: ["HAR"]),
    .library(name: "Presentation", targets: ["Presentation"]),
    .library(name: "Scripts", targets: ["Scripts"]),
    .library(name: "DeviceBridge", targets: ["DeviceBridge"]),
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
        ],
        // On Windows, servers' certificates are checked with Windows' own certificate functions.
        linkerSettings: [.linkedLibrary("crypt32", .when(platforms: [.windows]))]
    ),
    // zlib, for gzip and deflate. The Mac has it, and Linux has it as a package.
    .systemLibrary(name: "CZlib", providers: [.apt(["zlib1g-dev"]), .yum(["zlib-devel"])]),
    // zlib's own source, for Windows.
    .target(
        name: "CZlibBundled",
        exclude: ["LICENSE", "README.md"],
        // Its code is zlib's, unchanged, so its warnings aren't Reqly's to fix.
        cSettings: [.unsafeFlags(["-w"])]
    ),
    // Brotli's decoder, from its own source, for Windows and Linux.
    .target(
        name: "CBrotliBundled",
        exclude: ["LICENSE", "README.md"],
        // Its code is Brotli's, unchanged, so its warnings aren't Reqly's to fix.
        cSettings: [.unsafeFlags(["-w"])]
    ),
    .target(
        name: "BodyKit",
        dependencies: [
            .target(name: "CZlib", condition: .when(platforms: zlibSystems)),
            .target(name: "CZlibBundled", condition: .when(platforms: [.windows])),
            .target(name: "CBrotliBundled", condition: .when(platforms: brotliBuilders)),
        ]
    ),
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
    // What the apps show, worked out the same way on the Mac and on Windows: the request list
    // and bodies made ready to show.
    .target(name: "Presentation", dependencies: ["ReqlyModel", "BodyKit"]),
    // Android's debug bridge, adb, for pointing emulators at Reqly, and the emulators' own
    // processes, whose traffic goes to the emulator as a device, on the Mac and on Windows.
    .target(name: "DeviceBridge", dependencies: ["ReqlyModel"]),
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
        dependencies: ["TrafficStore", "ReqlyModel", "BodyKit", .product(name: "GRDB", package: "GRDB.swift")],
        // Sessions that Reqly for Mac 1.0 and Reqly for Windows saved, which the tests open.
        exclude: ["Sessions"]
    ),
    .testTarget(
        name: "BodyKitTests",
        dependencies: [
            "BodyKit",
            .target(name: "CZlib", condition: .when(platforms: zlibSystems)),
            .target(name: "CZlibBundled", condition: .when(platforms: [.windows])),
        ]
    ),
    .testTarget(name: "HARTests", dependencies: ["HAR", "ReqlyModel"]),
    .testTarget(name: "PresentationTests", dependencies: ["Presentation", "ReqlyModel", "BodyKit"]),
    .testTarget(name: "DeviceBridgeTests", dependencies: ["DeviceBridge", "ReqlyModel"]),
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
