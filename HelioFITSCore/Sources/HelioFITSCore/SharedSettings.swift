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
    public static var suite: UserDefaults? { UserDefaults(suiteName: suiteName) }

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
