// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TabMonitor",
    platforms: [.macOS(.v14)],
    products: [
        // El ejecutable de TabMonitor.app. Scripts/make-app.sh lo empaqueta y lo firma.
        .executable(name: "TabMonitor", targets: ["TabMonitor"]),
    ],
    targets: [
        .executableTarget(name: "TabMonitor"),
        .testTarget(name: "TabMonitorTests", dependencies: ["TabMonitor"]),
    ]
)
