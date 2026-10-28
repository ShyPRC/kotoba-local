// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "KotobaLocal", platforms: [.macOS("26.0")], products: [.executable(name: "KotobaLocal", targets: ["KotobaLocal"])], targets: [.executableTarget(name: "KotobaLocal", swiftSettings: [.swiftLanguageMode(.v5)]), .testTarget(name: "KotobaLocalTests", dependencies: ["KotobaLocal"], path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)])])
