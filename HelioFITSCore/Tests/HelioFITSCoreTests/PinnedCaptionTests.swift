//
//  PinnedCaptionTests.swift: pinned keywords in the caption, and the header
//  drawer's text (HF-13). Synthetic fixture only; never the real app group.
//

import Testing
import Foundation
@testable import HelioFITSCore

@Suite("pinned keywords and the header drawer")
struct PinnedCaptionTests {

    static func disk() throws -> FITSPreviewModel {
        let p = RepoPaths.fixture("synthetic_disk.fits").path
        try #require(FileManager.default.fileExists(atPath: p),
                     "missing fixture \(p): run scripts/make_fixtures.py --synthetic")
        let m = FITSPreviewModel.load(path: p, maxSide: 128)
        try #require(m.page != nil)
        return m
    }

    @Test("no pins: the caption is unchanged")
    func noPins() throws {
        let m = try Self.disk()
        #expect(m.caption(pinned: []) == m.caption())
    }

    @Test("pins append KEY=value in pin order; a key the HDU lacks is skipped")
    func pinsAppend() throws {
        let m = try Self.disk()
        let c = m.caption(pinned: ["INSTRUME", "NOSUCHKY", "CRPIX1"])
        #expect(c.hasPrefix(m.caption()))
        #expect(c.contains("INSTRUME=make_fixtures.py"), "\(c)")
        #expect(c.contains("CRPIX1="), "\(c)")
        #expect(!c.contains("NOSUCHKY"))
        let i = try #require(c.range(of: "INSTRUME="))
        let j = try #require(c.range(of: "CRPIX1="))
        #expect(i.lowerBound < j.lowerBound, "pin order is kept")
    }

    @Test("the pin key is new and byte-exact; typed lists are cleaned")
    func pinKey() throws {
        #expect(SharedSettings.pinnedKeywordsKey == "pinnedKeywords")
        #expect(SharedSettings.keywords(from: ["exptime, wavelnth", "EXPTIME  date-obs"])
                == ["EXPTIME", "WAVELNTH", "DATE-OBS"])
        let d = try #require(UserDefaults(suiteName: "HF13.PinnedCaptionTests"))
        SharedSettings.setPinnedKeywords(["crpix1", "crpix1"], in: d)
        #expect(SharedSettings.pinnedKeywords(in: d) == ["CRPIX1"])
        #expect(SharedSettings.pinnedKeywords(in: nil) == [])
    }

    @Test("drawer: pins first, then a rule, then the rest; a group narrows the rest")
    func drawer() throws {
        let m = try Self.disk()
        let cards = try #require(m.headerCards())
        let all = FITSHeader.drawerText(cards: cards, pinned: ["TELESCOP"])
        let lines = all.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("TELESCOP") == true, "\(lines.first ?? "")")
        #expect(lines.dropFirst().first?.allSatisfy { $0 == "-" } == true)
        let wcs = FITSHeader.drawerText(cards: cards, group: .wcs)
        #expect(wcs.contains("CRPIX1"))
        #expect(wcs.contains("RSUN_OBS"))
        #expect(!wcs.contains("TELESCOP"))
        let time = FITSHeader.drawerText(cards: cards, group: .time)
        #expect(time.contains("DATE-OBS"))
        #expect(!time.contains("CRPIX1"))
    }

    @Test("group patterns: trailing * is a prefix, ? is one character")
    func patterns() {
        #expect(FITSHeader.matches("CRPIX2", "CRPIX*"))
        #expect(FITSHeader.matches("PC1_2", "PC?_?"))
        #expect(!FITSHeader.matches("PC10_2", "PC?_?"))
        #expect(!FITSHeader.matches("EXPTIMEX", "EXPTIME"))
        #expect(FITSHeader.Group.exposure.contains("XPOSURE"))
    }

    @Test("cards in one 80-column run split the same as newline cards")
    func cardShapes() {
        let a = "TELESCOP= 'X'".padding(toLength: 80, withPad: " ", startingAt: 0)
        let b = "CRPIX1  =                 32.5".padding(toLength: 80, withPad: " ", startingAt: 0)
        #expect(FITSHeader.cardLines(a + b) == FITSHeader.cardLines(a + "\n" + b))
        #expect(FITSHeader.cardLines(a + b).count == 2)
    }
}
