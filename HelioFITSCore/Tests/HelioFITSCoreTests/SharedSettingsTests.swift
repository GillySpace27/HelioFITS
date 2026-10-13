import Foundation
import Testing
@testable import HelioFITSCore

/// The app-group suite name and keys are read by every installed copy of the app and
/// both Quick Look extensions. A one-character change silently drops every user's
/// folder rules, so they are pinned byte for byte.
struct SharedSettingsTests {

    /// A private suite, never the real app group: tests must not write Gilly's settings.
    static let scratchSuite = "HF10.SharedSettingsTests"

    @Test("suite name and keys are byte-identical to what shipped")
    func namesArePinned() {
        #expect(SharedSettings.suiteName == "UB45PPC2JS.com.gillyspace27.fits")
        #expect(SharedSettings.dirHDUKey == "dirHDU")
        #expect(SharedSettings.defaultHDUKey == "defaultHDU")
        #expect(SharedSettings.dirBookmarksKey == "dirBookmarks")
    }

    @Test("folder rule wins, then the global default, then -1")
    func selectedHDURule() throws {
        let d = try #require(UserDefaults(suiteName: Self.scratchSuite))
        d.set(["/data/punch": 2], forKey: SharedSettings.dirHDUKey)
        d.set(1, forKey: SharedSettings.defaultHDUKey)
        #expect(SharedSettings.selectedHDU(forFileAt: "/data/punch/a.fits", in: d) == 2)
        #expect(SharedSettings.selectedHDU(forFileAt: "/data/aia/b.fits", in: d) == 1)
        // A suite this test never writes has no default: auto (-1).
        let empty = try #require(UserDefaults(suiteName: Self.scratchSuite + ".empty"))
        #expect(SharedSettings.selectedHDU(forFileAt: "/data/aia/b.fits", in: empty) == -1)
        #expect(SharedSettings.selectedHDU(forFileAt: "/data/aia/b.fits", in: nil) == -1)
    }
}
