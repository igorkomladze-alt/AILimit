// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AILimits",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AILimitsCore", targets: ["AILimitsCore"]),
        .library(name: "AILimitsMac", targets: ["AILimitsMac"])
    ],
    targets: [
        // Ядро: без SwiftUI, AppKit и Security (план §2).
        .target(
            name: "AILimitsCore",
            path: "Sources/AILimitsCore"
        ),
        // Системная оболочка: Keychain, URLSession, уведомления, UI-модели.
        .target(
            name: "AILimitsMac",
            dependencies: ["AILimitsCore"],
            path: "Sources/AILimitsMac"
        ),
        .testTarget(
            name: "AILimitsCoreTests",
            dependencies: ["AILimitsCore"],
            path: "Tests/AILimitsCoreTests"
        ),
        .testTarget(
            name: "AILimitsMacTests",
            dependencies: ["AILimitsMac"],
            path: "Tests/AILimitsMacTests"
        )
    ]
)
