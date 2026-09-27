// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ffmpegHUD",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ffmpegHUDKit", targets: ["ffmpegHUDKit"]),
        .executable(name: "ffmpegHUD", targets: ["ffmpegHUD"]),
        // Installed as `ffmpeghud`; a distinct product name because ffmpegHUD and ffmpeghud
        // would collide on a case-insensitive volume.
        .executable(name: "ffmpegHUDCLI", targets: ["ffmpegHUDCLI"]),
    ],
    dependencies: [
        .package(path: "../hudkit"),
    ],
    targets: [
        // Pure core: preset catalog, argv builder, output naming, probe, progress, runner, jobs. No UI.
        .target(
            name: "ffmpegHUDKit",
            path: "Sources/ffmpegHUDKit"
        ),
        .executableTarget(
            name: "ffmpegHUD",
            dependencies: ["ffmpegHUDKit", .product(name: "HUDKit", package: "hudkit")],
            path: "Sources/ffmpegHUD",
            // Bundle files, assembled into the .app by hudkit/scripts/hud-build.sh.
            exclude: ["Resources"]
        ),
        // `ffmpeghud <command> [key=value ...]`: a thin client for ffmpegHUD's MacHUD control socket.
        .executableTarget(
            name: "ffmpegHUDCLI",
            dependencies: ["ffmpegHUDKit", .product(name: "HUDKit", package: "hudkit")],
            path: "Sources/ffmpegHUDCLI"
        ),
        .testTarget(
            name: "ffmpegHUDKitTests",
            dependencies: ["ffmpegHUDKit"],
            path: "Tests/ffmpegHUDKitTests"
        ),
        // Host logic in the app target (socket actions against a real model) and the shipped
        // manifest, settings schema and Info.plist.
        .testTarget(
            name: "ffmpegHUDTests",
            dependencies: ["ffmpegHUD", "ffmpegHUDKit", .product(name: "HUDKit", package: "hudkit")],
            path: "Tests/ffmpegHUDTests"
        ),
    ]
)
