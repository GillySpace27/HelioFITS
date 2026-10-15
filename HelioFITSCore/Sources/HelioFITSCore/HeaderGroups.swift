//
//  HeaderGroups.swift: what the Quick Look header drawer and the iOS header sheet
//  show (HF-13). One HDU's cards, pinned keywords first, optionally narrowed to a
//  quick group. The groups match keyword NAMES only (a name ending in `*` is a
//  prefix); they say nothing about what any instrument writes.
//

import Foundation

extension FITSHeader {

    /// The one-click groups in the drawer.
    public enum Group: String, CaseIterable {
        case time = "Time", instrument = "Instrument", wcs = "WCS", exposure = "Exposure"

        /// Keyword-name patterns; a trailing `*` matches any suffix.
        public var patterns: [String] {
            switch self {
            case .time:
                return ["DATE*", "T_OBS", "T_REC", "TIME*", "TSTART", "TSTOP", "TELAPSE", "MJD*", "JD*", "TIMESYS"]
            case .instrument:
                return ["TELESCOP", "INSTRUME", "DETECTOR", "OBSRVTRY", "ORIGIN", "WAVELNTH", "WAVEUNIT",
                        "WAVE_STR", "FILTER*", "LEVEL", "LVL_NUM", "OBJECT", "OBS_MODE", "BUNIT"]
            case .wcs:
                return ["WCS*", "CTYPE*", "CUNIT*", "CRPIX*", "CRVAL*", "CDELT*", "CROTA*", "PC?_?", "CD?_?",
                        "PV*", "LONPOLE", "LATPOLE", "RADESYS", "RSUN*", "DSUN*", "HGLN_OBS", "HGLT_OBS",
                        "CRLN_OBS", "CRLT_OBS"]
            case .exposure:
                return ["EXPTIME", "XPOSURE", "EXPOSURE", "EXP_TIME", "EXPTDUR", "INTTIME", "INT_TIME",
                        "NSUMEXP", "NUMEXP"]
            }
        }

        /// Whether `key` (a trimmed keyword name) belongs to this group.
        public func contains(_ key: String) -> Bool {
            patterns.contains { FITSHeader.matches(key, $0) }
        }
    }

    /// `pattern` against a keyword name: `*` at the end matches any suffix, `?`
    /// matches one character. Case-insensitive.
    static func matches(_ key: String, _ pattern: String) -> Bool {
        let k = Array(key.uppercased()), p = Array(pattern.uppercased())
        if p.last == "*" {
            let head = p.dropLast()
            return k.count >= head.count && zip(k, head).allSatisfy { $1 == "?" || $0 == $1 }
        }
        return k.count == p.count && zip(k, p).allSatisfy { $1 == "?" || $0 == $1 }
    }

    /// Cards as lines: `FITSRenderer.cards` may hand back newline-separated cards
    /// or one run of 80-character cards (the same two shapes `cardVal` reads).
    /// Trailing blanks and blank cards are dropped.
    public static func cardLines(_ cards: String) -> [String] {
        let raw: [String] = cards.contains("\n")
            ? cards.split(separator: "\n").map(String.init)
            : stride(from: 0, to: cards.count, by: 80).map {
                let s = cards.index(cards.startIndex, offsetBy: $0)
                let e = cards.index(s, offsetBy: min(80, cards.count - $0))
                return String(cards[s..<e])
            }
        return raw.map { $0.trimmedTrailing() }.filter { !$0.isEmpty }
    }

    /// The keyword name of one card (columns 1 to 8, trimmed).
    public static func keyword(of card: String) -> String {
        String(card.prefix(8)).trimmingCharacters(in: .whitespaces)
    }

    /// The drawer's text for one HDU: pinned keywords first, in pin order, then a
    /// rule, then every other card; with a `group`, only that group's cards (pins
    /// still lead). Empty when nothing matches.
    public static func drawerText(cards: String, group: Group? = nil, pinned: [String] = []) -> String {
        let lines = cardLines(cards)
        let pins = pinned.map { $0.uppercased() }
        let pinnedLines = pins.compactMap { k in lines.first { keyword(of: $0) == k } }
        let rest = lines.filter { line in
            let k = keyword(of: line)
            return !pins.contains(k) && (group?.contains(k) ?? true)
        }
        if pinnedLines.isEmpty { return rest.joined(separator: "\n") }
        if rest.isEmpty { return pinnedLines.joined(separator: "\n") }
        return (pinnedLines + [String(repeating: "-", count: 40)] + rest).joined(separator: "\n")
    }
}
