//
//  CallbackSubscriberTests.swift: a published callback needs a subscriber in
//  every host that creates its publisher (projects/heliofits.md:80). Bitten
//  twice: a host that never assigned onFullRes left the filtered image stuck,
//  and #13.
//
//  A source scan, so a heuristic. It reads `var on<Name>:` declarations from the
//  canvas sources and looks for `.on<Name> =` in every host, ignoring lines that
//  start with //. Exceptions live in `allowlist` with a reason; an entry whose
//  callback is no longer declared fails, so the list cannot go stale.
//
//  Rule for new code: a new `var on<Name>` on FITSImageCanvas or
//  CanvasScrollView is assigned in every host, or gets an allowlist entry.
//

import Testing
import Foundation

@Suite("Callback subscribers")
struct CallbackSubscriberTests {

    /// Declared callbacks that no host has to assign, each with its reason.
    /// onZoomChanged waits on Gilly's call (register question 15): wire it, or keep it here.
    static let allowlist: [String: String] = [
        "onZoomChanged": "canvas refreshes its own readout after firing (L382, L446); no host needs it yet",
    ]

    /// Where FITSImageCanvas lives. HF-7 moves it to HelioFITSMacUI/; the first file that exists wins.
    static let canvasFiles = ["HelioFITSMacUI/FITSImageCanvas.swift", "HelioFITSExtension/FITSPreviewCore.swift"]
    /// The Mac hosts known today; the scan also finds any new one.
    static let knownMacHosts = ["HelioFITSExtension/PreviewViewController.swift", "HelioFITS/HeaderViewer.swift"]
    /// The iOS canvas (CanvasScrollView) and its host (ZoomCanvas) share this file.
    static let iosCanvasFile = "HelioFITS-iOS/App/ViewerView.swift"
    /// App and extension source folders. The core package and the tests are not hosts.
    static let hostFolders = ["HelioFITS", "HelioFITSExtension", "HelioFITSThumbnail", "HelioFITSMacUI", "HelioFITS-iOS"]

    // MARK: scanning

    static func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: RepoPaths.url(relative).path)
    }

    /// Source text without whole-line `//` comments, so a commented-out assignment counts as missing.
    static func code(_ relative: String) throws -> String {
        let text = try String(contentsOf: RepoPaths.url(relative), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Callback names from `var on<Name>:` declarations, in file order.
    static func declared(in source: String) throws -> [String] {
        let re = try NSRegularExpression(pattern: #"\bvar\s+(on[A-Z]\w*)\s*:"#)
        let ns = source as NSString
        return re.matches(in: source, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    /// True when `source` assigns `.<name> =` (an assignment, not `==`).
    static func assigns(_ name: String, in source: String) -> Bool {
        source.range(of: #"\.\#(name)\s*=(?!=)"#, options: .regularExpression) != nil
    }

    /// Every .swift file under the host folders, as repository-relative paths.
    static func hostSources() -> [String] {
        let root = RepoPaths.root.standardizedFileURL.path + "/"
        var out: [String] = []
        for folder in hostFolders where exists(folder) {
            guard let e = FileManager.default.enumerator(at: RepoPaths.url(folder),
                                                         includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in e where u.pathExtension == "swift" {
                let p = u.standardizedFileURL.path
                out.append(p.hasPrefix(root) ? String(p.dropFirst(root.count)) : p)
            }
        }
        return out.sorted()
    }

    /// Host files whose code (comments stripped) contains `needle`.
    static func files(containing needle: String) throws -> [String] {
        try hostSources().filter { try code($0).contains(needle) }
    }

    static func canvasFile() throws -> String {
        try #require(canvasFiles.first(where: { exists($0) }),
                     "FITSImageCanvas source not found at \(canvasFiles); point canvasFiles at its new home")
    }

    // MARK: tests

    @Test("the scan finds the callbacks it guards, and the allowlist is current")
    func scanFindsCallbacks() throws {
        let canvasPath = try Self.canvasFile()
        let canvas = try Self.declared(in: Self.code(canvasPath))
        for name in ["onScrollStep", "onHover", "onRegion"] {
            #expect(canvas.contains(name),
                    "\(name) is not declared in \(canvasPath) (found \(canvas)); update the scanner if it moved")
        }
        let ios = try Self.declared(in: Self.code(Self.iosCanvasFile))
        #expect(ios.contains("onSample") && ios.contains("onSwipe"),
                "CanvasScrollView callbacks not found in \(Self.iosCanvasFile) (found \(ios))")
        for name in Self.allowlist.keys.sorted() {
            #expect(canvas.contains(name) || ios.contains(name),
                    "allowlist entry \(name) is no longer declared; drop the entry")
        }
    }

    @Test("every Mac host that creates FITSImageCanvas assigns each canvas callback")
    func macHostsAssignCanvasCallbacks() throws {
        let canvasPath = try Self.canvasFile()
        let names = try Self.declared(in: Self.code(canvasPath)).filter { Self.allowlist[$0] == nil }
        let hosts = try Self.files(containing: "FITSImageCanvas(")
        for known in Self.knownMacHosts {
            #expect(hosts.contains(known), "expected \(known) to create a FITSImageCanvas; hosts found: \(hosts)")
        }
        for host in hosts {
            let text = try Self.code(host)
            for name in names {
                #expect(Self.assigns(name, in: text),
                        "\(host) creates FITSImageCanvas but never assigns \(name) (declared in \(canvasPath)); assign it, or add it to CallbackSubscriberTests.allowlist with a reason")
            }
        }
    }

    @Test("every iOS host that creates CanvasScrollView assigns each of its callbacks")
    func iosHostsAssignCanvasCallbacks() throws {
        let names = try Self.declared(in: Self.code(Self.iosCanvasFile)).filter { Self.allowlist[$0] == nil }
        let hosts = try Self.files(containing: "CanvasScrollView(")
        #expect(hosts.contains(Self.iosCanvasFile),
                "expected \(Self.iosCanvasFile) to create a CanvasScrollView; hosts found: \(hosts)")
        for host in hosts {
            let text = try Self.code(host)
            for name in names {
                #expect(Self.assigns(name, in: text),
                        "\(host) creates CanvasScrollView but never assigns \(name) (declared in \(Self.iosCanvasFile)); assign it, or add it to CallbackSubscriberTests.allowlist with a reason")
            }
        }
    }

    @Test("every file that calls prefetchFullRes() assigns onFullRes")
    func prefetchCallersAssignOnFullRes() throws {
        let callers = try Self.files(containing: ".prefetchFullRes()")
        #expect(callers.count >= 3,
                "expected the Quick Look preview, the viewer window and iOS to call prefetchFullRes(); found \(callers)")
        for file in callers {
            let text = try Self.code(file)
            #expect(Self.assigns("onFullRes", in: text),
                    "\(file) calls prefetchFullRes() but never assigns onFullRes: off-main renders (full-res buffer, RHEF) land with nobody to redraw")
        }
    }
}
