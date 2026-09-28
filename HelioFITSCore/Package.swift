// swift-tools-version:5.10
// The platform-neutral half of HelioFITS: reading FITS (CFITSIO + fitsshim),
// solar WCS, colormaps, stretch, RHEF, and rendering to CGImage/PNG. No AppKit,
// no Quick Look: the Mac app, its two extensions, and a future iOS app all link it.
// Language mode 5, same as the app targets.
import PackageDescription

let package = Package(
    name: "HelioFITSCore",
    platforms: [.macOS("14.5")],
    products: [.library(name: "HelioFITSCore", targets: ["HelioFITSCore"])],
    targets: [
        // Built by HelioFITSExtension/cfitsio/build-universal.sh: libcfitsio.a with
        // fitsshim.c baked in, plus its headers and a module map (`import CFITSIO`).
        .binaryTarget(name: "CFITSIO", path: "CFITSIO.xcframework"),
        .target(name: "HelioFITSCore", dependencies: ["CFITSIO"],
                linkerSettings: [.linkedLibrary("z")]),
    ]
)
