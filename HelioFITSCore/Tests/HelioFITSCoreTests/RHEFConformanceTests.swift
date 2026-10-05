//
//  RHEFConformanceTests.swift: FITSRenderer.rhefEqualize against the fastRHEF golden RHEF
//  bundle (RH-6). The bundle is read from RHEF_GOLDEN_DIR, else from HelioFITSCore/Tests/golden
//  (outside the test target's folder, so SwiftPM never treats its files as resources). That
//  folder is not committed: fastRHEF is private, and copying its bundle into this public
//  repository (fastRHEF tools/sync_golden.sh) waits on Gilly's yes. Until then this test is
//  skipped in report mode.
//
//  Only binning=equal-width cases run: rhefEqualize bins equal-width to maxRadius from the
//  radii it is handed, and the bundle's generator asserts that this binning reproduces the
//  stored bin_index on exactly those cases. Upsilon "none" runs as upsilon 1, the identity.
//  Each case prints one RHEF-CONFORMANCE line, then a summary line.
//
//  Mode: RHEF_CONFORMANCE_MODE is report (default) or enforce. Report mode records every
//  mismatch as a known issue. Enforce mode records a mismatch as a known issue only when the
//  case's sensitive_to names one of `declared`; any other mismatch fails. Without a bundle the
//  test is skipped in report mode and fails in enforce mode.
//
//    RHEF_GOLDEN_DIR=<fastRHEF>/golden swift test --package-path HelioFITSCore --filter RHEFConformanceTests
//

import Foundation
import Testing
@testable import HelioFITSCore

private enum Golden {
    static let mode = ProcessInfo.processInfo.environment["RHEF_CONFORMANCE_MODE"] ?? "report"
    static let dir: URL = {
        if let d = ProcessInfo.processInfo.environment["RHEF_GOLDEN_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d)
        }
        return RepoPaths.url("HelioFITSCore/Tests/golden")
    }()
    static var present: Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path)
    }
}

private struct GoldenFileError: Error, CustomStringConvertible {
    let description: String
}

@Suite("RHEF conformance")
struct RHEFConformanceTests {

    static let impl = "heliofits-swift"
    static let convention = "oRHEF-2.0"
    /// The deviations of the heliofits-swift row in fastRHEF conventions/implementations.json.
    static let declared: Set<String> = ["UPS-MEAN", "TIES-TOL", "KEY-QUANT", "GEOM-GRID", "DTYPE-IN"]

    @Test("rhefEqualize matches the golden bundle on its equal-width cases",
          .enabled(if: Golden.present || Golden.mode == "enforce"))
    func goldenBundle() throws {
        try #require(Golden.mode == "report" || Golden.mode == "enforce",
                     "RHEF_CONFORMANCE_MODE must be report or enforce, not \(Golden.mode)")
        let manifestData = try Data(contentsOf: Golden.dir.appendingPathComponent("manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        let bundle = manifest?["bundle_version"] as? String ?? "unknown"

        var pass = 0, report = 0, fail = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: Golden.dir.path).sorted() {
            let caseDir = Golden.dir.appendingPathComponent(name)
            let propsURL = caseDir.appendingPathComponent("case.properties")
            guard FileManager.default.fileExists(atPath: propsURL.path) else { continue }
            let p = try properties(propsURL)
            guard p["binning"] == "equal-width" else { continue }

            let shape = try #require(p["shape"]).split(separator: ",").compactMap { Int($0) }
            try #require(shape.count == 2, "\(name): bad shape")
            let n = shape[0] * shape[1]
            let values = try floats(caseDir.appendingPathComponent("input.f32"), count: n)
            let radii = try doubles(caseDir.appendingPathComponent("radii.f64"), count: n)
            let expected = try floats(caseDir.appendingPathComponent("expected_\(Self.convention).f32"), count: n)
            let ups = try #require(p["upsilon"])
            let pair = ups == "none" ? [1.0, 1.0] : ups.split(separator: ",").compactMap { Double($0) }
            try #require(pair.count == 2 && pair[0] == pair[1],
                         "\(name): rhefEqualize takes one upsilon, the case has \(ups)")
            let maxRadius = try #require(p["max_radius"].flatMap { Double($0) })
            let nbins = try #require(p["nbins"].flatMap { Int($0) })
            let tol = try #require(p["tol_f32"].flatMap { Double($0) })
            let sensitive = Set((p["sensitive_to"] ?? "none").split(separator: ",").map(String.init))

            let out = FITSRenderer.rhefEqualize(values: values, radii: radii, maxRadius: maxRadius,
                                                nbins: nbins, upsilon: pair[0])
            let diff = maxAbsDiff(out, expected)
            let within = !diff.isNaN && diff <= tol
            let result = within ? "PASS"
                : (Golden.mode == "report" || !sensitive.isDisjoint(with: Self.declared)) ? "REPORT" : "FAIL"
            print("RHEF-CONFORMANCE impl=\(Self.impl) bundle=\(bundle) case=\(name) "
                  + "convention=\(Self.convention) max_abs_diff=\(shown(diff)) result=\(result)")
            switch result {
            case "PASS":
                pass += 1
            case "REPORT":
                report += 1
                withKnownIssue("\(name): divergence that is declared or in report mode", isIntermittent: true) {
                    #expect(within, "\(name): max |diff| \(shown(diff)) > \(tol)")
                }
            default:
                fail += 1
                #expect(within, "\(name): max |diff| \(shown(diff)) > \(tol)")
            }
        }
        print("RHEF-CONFORMANCE impl=\(Self.impl) summary pass=\(pass) report=\(report) fail=\(fail) mode=\(Golden.mode)")
        #expect(pass + report + fail > 0, "no equal-width case in \(Golden.dir.path)")
    }
}

/// The key=value lines of a java.util.Properties file (the bundle uses no escapes).
private func properties(_ url: URL) throws -> [String: String] {
    var out: [String: String] = [:]
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("#"), !t.hasPrefix("!"), let eq = t.firstIndex(of: "=") else { continue }
        out[String(t[..<eq])] = String(t[t.index(after: eq)...])
    }
    return out
}

private func floats(_ url: URL, count: Int) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count == count * 4 else {
        throw GoldenFileError(description: "\(url.lastPathComponent): \(data.count) bytes, expected \(count * 4)")
    }
    var bits = [UInt32](repeating: 0, count: count)
    _ = bits.withUnsafeMutableBytes { data.copyBytes(to: $0) }
    return bits.map { Float(bitPattern: UInt32(littleEndian: $0)) }
}

private func doubles(_ url: URL, count: Int) throws -> [Double] {
    let data = try Data(contentsOf: url)
    guard data.count == count * 8 else {
        throw GoldenFileError(description: "\(url.lastPathComponent): \(data.count) bytes, expected \(count * 8)")
    }
    var bits = [UInt64](repeating: 0, count: count)
    _ = bits.withUnsafeMutableBytes { data.copyBytes(to: $0) }
    return bits.map { Double(bitPattern: UInt64(littleEndian: $0)) }
}

/// max |got - want| where both are finite; NaN when the two NaN patterns differ.
private func maxAbsDiff(_ got: [Float], _ want: [Float]) -> Double {
    var worst = 0.0
    for (g, w) in zip(got, want) {
        if g.isNaN || w.isNaN {
            if g.isNaN != w.isNaN { return .nan }
            continue
        }
        worst = max(worst, Double(abs(g - w)))
    }
    return worst
}

private func shown(_ x: Double) -> String { x.isNaN ? "nan" : String(format: "%.3e", x) }
