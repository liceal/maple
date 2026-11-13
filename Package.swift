// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Maple",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "Maple",
            path: "Sources/Maple"
        ),
        .executableTarget(
            name: "MapleInstaller",
            path: "Sources/MapleInstaller"
        )
    ]
)
