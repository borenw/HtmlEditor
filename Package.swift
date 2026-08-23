// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "HtmlEditor",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "HtmlEditor", path: "Sources/HtmlEditor")
    ]
)
