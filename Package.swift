// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BriefKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "BriefKit", targets: ["BriefKit"]),
    ],
    targets: [
        .target(name: "BriefKit"),
    ]
)
