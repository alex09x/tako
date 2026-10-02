// swift-tools-version:5.9
import PackageDescription

// A window with a shell in it: the least a macOS app needs to embed TakoCore.
// Depends on this repository's root package; an app outside it would use
//   .package(url: "https://github.com/alex09x/tako", exact: "<release>")
let package = Package(
    name: "TakoSample",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "TakoCoreUI", path: "../..")],
    targets: [
        .executableTarget(
            name: "TakoSample",
            dependencies: [.product(name: "TakoCoreUI", package: "TakoCoreUI")]
        ),
    ]
)
