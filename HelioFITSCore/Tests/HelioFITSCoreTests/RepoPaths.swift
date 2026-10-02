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
}
