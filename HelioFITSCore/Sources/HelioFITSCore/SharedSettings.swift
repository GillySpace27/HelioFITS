import Foundation

/// The app-group settings the Mac app writes and its Quick Look extensions read.
/// The suite name and keys are a data contract with every installed copy: append-only
/// and byte-exact (SharedSettingsTests pins them). Keys owned elsewhere stay there:
/// `howItWorks` (app group, RELEASING.md) and `hideWelcome` (UserDefaults.standard).
public enum SharedSettings {
    public static let suiteName = "UB45PPC2JS.com.gillyspace27.fits"
    public static let dirHDUKey = "dirHDU"               // [String: Int], folder path to HDU
    public static let defaultHDUKey = "defaultHDU"       // Int
    public static let dirBookmarksKey = "dirBookmarks"   // [String: Data], reserved for security-scoped folder bookmarks (HF-10 Task 8)
    /// Header keywords shown in every caption, in pin order (HF-13). The Mac app writes
    /// it; the Quick Look extension only reads it. iOS keeps the same key in its own
    /// standard defaults (no app group there).
    public static let pinnedKeywordsKey = "pinnedKeywords"   // [String]
    /// Opt-in RHEF cover on Finder thumbnails of files with a solar limb (HF-20). Off
    /// when absent. Slower per icon, so the Mac app offers Refresh Icons after a change.
    public static let rhefCoversKey = "rhefCovers"           // Bool
    public static var suite: UserDefaults? { UserDefaults(suiteName: suiteName) }

    /// The pinned keywords, cleaned (see `keywords(from:)`).
    public static func pinnedKeywords(in d: UserDefaults? = SharedSettings.suite) -> [String] {
        keywords(from: d?.stringArray(forKey: pinnedKeywordsKey) ?? [])
    }

    /// Store `keys`, cleaned, as the pinned keywords. Nil defaults: nothing happens.
    public static func setPinnedKeywords(_ keys: [String], in d: UserDefaults? = SharedSettings.suite) {
        d?.set(keywords(from: keys), forKey: pinnedKeywordsKey)
    }

    /// Keyword names as typed or stored: split on commas and blanks, upper-cased,
    /// empty and repeated names dropped, first-seen order kept.
    public static func keywords(from list: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for item in list {
            for k in item.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }) {
                let key = k.uppercased()
                if seen.insert(key).inserted { out.append(key) }
            }
        }
        return out
    }

    /// Which HDU to display for a file: per-directory rule wins, then the
    /// global default, else -1 (auto = first image HDU).
    public static func selectedHDU(forFileAt path: String) -> Int {
        selectedHDU(forFileAt: path, in: suite)
    }

    /// The same rule against any defaults store; tests pass a private suite.
    static func selectedHDU(forFileAt path: String, in d: UserDefaults?) -> Int {
        guard let d = d else { return -1 }
        let dir = (path as NSString).deletingLastPathComponent
        if let per = d.dictionary(forKey: dirHDUKey) as? [String: Int], let v = per[dir] {
            return v
        }
        return d.object(forKey: defaultHDUKey) != nil ? d.integer(forKey: defaultHDUKey) : -1
    }
}
