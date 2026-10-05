// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KandevKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "KandevKit", targets: ["KandevKit"]),
        .executable(name: "kandev-probe", targets: ["KandevProbe"]),
    ],
    targets: [
        .target(name: "KandevKit"),
        .executableTarget(name: "KandevProbe", dependencies: ["KandevKit"]),
        .testTarget(name: "KandevKitTests", dependencies: ["KandevKit"]),
    ]
)
