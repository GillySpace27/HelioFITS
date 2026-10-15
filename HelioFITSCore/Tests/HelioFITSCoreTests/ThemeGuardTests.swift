//
//  ThemeGuardTests.swift: no literal colours or fixed font sizes in the viewer UI (HF-18).
//
//  Colours come from Palette via Theme.color; fonts from Theme.font, Theme.mono and friends.
//  Theme.swift is the one place that may construct an NSColor or an NSFont from numbers.
//  Same pattern as CallbackSubscriberTests: read the sources, fail with file:line.
//

import Foundation
import Testing

@Suite("Theme guard")
struct ThemeGuardTests {

    static let folders = ["HelioFITSMacUI"]
    static let files = ["HelioFITSExtension/PreviewViewController.swift", "HelioFITS/HeaderViewer.swift"]
    static let exempt: Set<String> = ["HelioFITSMacUI/Theme.swift"]
    /// Substrings that mean "a literal colour or a fixed font size".
    static let forbidden = ["NSColor(calibrated", "ystemFont(ofSize:"]

    static func sources() throws -> [String] {
        var out = files
        for dir in folders {
            let names = try FileManager.default.contentsOfDirectory(atPath: RepoPaths.url(dir).path)
            out += names.filter { $0.hasSuffix(".swift") }.sorted().map { dir + "/" + $0 }
        }
        return out.filter { !exempt.contains($0) }
    }

    static func offenders(in text: String, file: String) -> [String] {
        var out: [String] = []
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            if forbidden.contains(where: { line.contains($0) }) { out.append("\(file):\(i + 1)") }
        }
        return out
    }

    @Test("no NSColor(calibrated...) and no systemFont(ofSize:) outside Theme.swift")
    func noLiterals() throws {
        var found: [String] = []
        for rel in try Self.sources() {
            found += Self.offenders(in: try String(contentsOf: RepoPaths.url(rel), encoding: .utf8), file: rel)
        }
        #expect(found.isEmpty, "\(found.count) literal colour or font lines; use Theme.color(Palette.<role>) / Theme.font: \(found.joined(separator: ", "))")
    }

    @Test("the guard can fail: it flags a literal colour and a fixed font")
    func guardCanFail() {
        let bad = "let a = NSColor(calibratedWhite: 0.5, alpha: 1)\nlet b = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)\n// NSColor(calibratedWhite: 0, alpha: 1)\nlet ok = Theme.color(Palette.canvas)\n"
        #expect(Self.offenders(in: bad, file: "x.swift") == ["x.swift:1", "x.swift:2"])
    }

    @Test("Theme.swift exists, so the guard cannot pass by scanning nothing")
    func themeExists() throws {
        #expect(FileManager.default.fileExists(atPath: RepoPaths.url("HelioFITSMacUI/Theme.swift").path))
        #expect(try Self.sources().count >= 5)
    }
}
