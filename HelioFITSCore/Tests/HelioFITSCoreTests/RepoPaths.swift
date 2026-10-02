import Foundation

/// Repository paths for tests in HelioFITSCore/Tests/HelioFITSCoreTests.
enum RepoPaths {
    /// Repository root: this file's directory, then Tests, HelioFITSCore, root.
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }
    /// A committed fixture in HelioFITSTests/Fixtures (written by scripts/make_fixtures.py). Added by HF-5.
    static func fixture(_ name: String) -> URL { url("HelioFITSTests/Fixtures/" + name) }
}
