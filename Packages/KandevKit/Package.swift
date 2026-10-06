// swift-tools-version: 6.2
import PackageDescription

// Approachable concurrency, named feature by feature, the same way the app targets do it in
// `project.yml` — a package cannot inherit an Xcode build setting.
//
// `NonisolatedNonsendingByDefault` is the one that does the work: a `nonisolated async` function
// runs on its *caller's* actor instead of hopping to the global executor and back, so a chain of
// small async helpers stops costing a suspension point per link. This module is mostly small async
// helpers — decoding, reading state, handing values across — which is exactly the shape that pays
// for the hop and gets nothing from it.
//
// `InferIsolatedConformances`, the other half of the Xcode umbrella, is deliberately *not* listed.
// With it on, a view built inside an `@MainActor` context infers a main-actor-isolated `View`
// conformance, and MarkdownUI cannot accept one back; the app target measured ninety-nine warnings
// from it and none of them were its own to fix.
let approachableConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "KandevKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "KandevKit", targets: ["KandevKit"]),
        .executable(name: "kandev-probe", targets: ["KandevProbe"]),
    ],
    targets: [
        .target(name: "KandevKit", swiftSettings: approachableConcurrency),
        .executableTarget(
            name: "KandevProbe",
            dependencies: ["KandevKit"],
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "KandevKitTests",
            dependencies: ["KandevKit"],
            swiftSettings: approachableConcurrency
        ),
    ]
)
