import Foundation

public enum Lang: String, Codable, CaseIterable, Sendable {
    case en, ru
}

/// Physical key geometry for the two layouts, used to judge how likely a mis-hit is.
public enum Keyboard {
    public static let rows: [Lang: [[Character]]] = [
        .en: ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map(Array.init),
        .ru: ["йцукенгшщзхъ", "фывапролджэ", "ячсмитьбю"].map(Array.init),
    ]
    /// Horizontal stagger of each row, in key widths.
    public static let rowOffsets: [Double] = [0, 0.25, 0.75]

    private static let positions: [Character: (x: Double, y: Double)] = {
        var map: [Character: (x: Double, y: Double)] = [:]
        for layout in rows.values {
            for (y, row) in layout.enumerated() {
                for (x, key) in row.enumerated() {
                    map[key] = (Double(x) + rowOffsets[y], Double(y))
                }
            }
        }
        return map
    }()

    /// True when the two keys touch, including diagonal neighbours on the next row.
    public static func isAdjacent(_ a: Character, _ b: Character) -> Bool {
        guard a != b, let p = positions[a], let q = positions[b] else { return false }
        let dx = p.x - q.x, dy = p.y - q.y
        return dx * dx + dy * dy < 1.6
    }

    /// Language of a normalized word, or nil when it mixes scripts or contains non-letters.
    public static func language(of word: String) -> Lang? {
        var result: Lang?
        for scalar in word.unicodeScalars {
            let lang: Lang
            switch scalar.value {
            case 0x61...0x7A: lang = .en
            case 0x430...0x44F: lang = .ru
            default: return nil
            }
            if result == nil {
                result = lang
            } else if result != lang {
                return nil
            }
        }
        return result
    }

    /// Lowercase and fold ё into е, which most people type interchangeably.
    public static func normalize(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "ё", with: "е")
    }
}
