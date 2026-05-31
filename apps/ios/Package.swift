// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "strg-ios",
    platforms: [
        .iOS(.v17)
    ],
    targets: [
        .target(
            name: "strg-ios",
            path: "strg-ios",
            exclude: ["Resources/Info.plist"]
        ),
    ]
)
