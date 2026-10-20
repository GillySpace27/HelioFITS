// swift-tools-version:5.10
// HelioFITSCore for the suite's other apps (Heliad first), from the repository root:
// SwiftPM resolves a package by URL only through a root manifest. Same sources, same
// CFITSIO binary and same settings as HelioFITSCore/Package.swift, which stays the one
// the Xcode project and `swift test --package-path HelioFITSCore` use. Products only:
// the tests and the heliofits command stay in that package.
import PackageDescription

let package = Package(
    name: "HelioFITS",
    platforms: [.macOS("14.5"), .iOS("17.0")],
    products: [.library(name: "HelioFITSCore", targets: ["HelioFITSCore"])],
    targets: [
        .binaryTarget(name: "CFITSIO", path: "HelioFITSCore/CFITSIO.xcframework"),
        .target(name: "HelioFITSCore", dependencies: ["CFITSIO"],
                path: "HelioFITSCore/Sources/HelioFITSCore",
                linkerSettings: [.linkedLibrary("z")]),
    ]
)
