// swift-tools-version:5.9
import PackageDescription

// A window with a shell in it: the least a macOS app needs to embed TakoCore.
// Built against this checkout: the package under swift/ links the engine
// that scripts/build-xcframework.sh builds here, so the sample always matches
// the sources beside it. An app outside the repository uses a release:
//   .package(url: "https://github.com/alex09x/tako", exact: "<release>")
let package = Package(
    name: "TakoSample",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "TakoCoreUI", path: "../../swift")],
    targets: [
        .executableTarget(
            name: "TakoSample",
            dependencies: [.product(name: "TakoCoreUI", package: "TakoCoreUI")]
        ),
    ]
)
