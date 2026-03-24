// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GPUMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "GPUMonitor",
            path: "Sources/GPUMonitor",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        )
    ]
)
