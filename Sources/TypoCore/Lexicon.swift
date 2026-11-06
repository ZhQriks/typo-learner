import Foundation

/// A frequency-ranked word list with a symmetric-delete index for fast candidate lookup.
public final class Lexicon: @unchecked Sendable {
    public let lang: Lang
    public let words: [String]
    private let characters: [[Character]]
    private let probabilities: [Double]
    private let ids: [String: Int32]
    // Sorted hashes of each word and each of its one-letter deletions.
    private let deleteKeys: [UInt64]
    private let deleteIds: [Int32]

    /// Subtitle-corpus fragments of contractions ("didn" from "didn't") that must never be suggested.
    private static let excluded: Set<String> = [
        "ll", "re", "ve", "didn", "doesn", "isn", "wasn", "couldn", "wouldn", "shouldn",
        "aren", "weren", "hasn", "haven", "hadn", "don", "ain", "mustn", "needn",
    ]
    private static let singleLetters: Set<String> = ["a", "i", "я", "в", "и", "с", "к", "о", "у", "а"]

    public init(lang: Lang, entries: [(String, Double)]) {
        self.lang = lang
        var merged: [String: Double] = [:]
        for (raw, count) in entries {
            let word = Keyboard.normalize(raw)
            guard Keyboard.language(of: word) == lang,
                  word.count > 1 || Self.singleLetters.contains(word),
                  !Self.excluded.contains(word) else { continue }
            merged[word, default: 0] += count
        }
        let sorted = merged.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let total = sorted.reduce(0) { $0 + $1.value }
        words = sorted.map(\.key)
        probabilities = sorted.map { $0.value / total }
        characters = words.map(Array.init)

        var ids = [String: Int32](minimumCapacity: words.count)
        for (i, word) in words.enumerated() { ids[word] = Int32(i) }
        self.ids = ids

        var pairs: [(UInt64, Int32)] = []
        pairs.reserveCapacity(words.count * 9)
        for (i, word) in words.enumerated() {
            let scalars = word.unicodeScalars.map(\.value)
            for skip in -1..<scalars.count {
                pairs.append((Self.hash(scalars, skipping: skip), Int32(i)))
            }
        }
        pairs.sort { $0.0 < $1.0 }
        deleteKeys = pairs.map(\.0)
        deleteIds = pairs.map(\.1)
    }

    /// Reads a "word count" per line file.
    public static func load(lang: Lang, from url: URL) throws -> Lexicon {
        let text = try String(contentsOf: url, encoding: .utf8)
        var entries: [(String, Double)] = []
        for line in text.split(separator: "\n") {
            guard let space = line.lastIndex(of: " "),
                  let count = Double(line[line.index(after: space)...]) else { continue }
            entries.append((String(line[..<space]), count))
        }
        return Lexicon(lang: lang, entries: entries)
    }

    public var count: Int { words.count }
    public func id(of word: String) -> Int32? { ids[word] }
    public func probability(_ id: Int32) -> Double { probabilities[Int(id)] }
    public func characters(_ id: Int32) -> [Character] { characters[Int(id)] }

    /// Words that share a string with `typed` after deleting at most one letter from each.
    /// Covers every single edit (including swaps) plus some double edits; callers verify the distance.
    public func candidates(for typed: String) -> Set<Int32> {
        let scalars = typed.unicodeScalars.map(\.value)
        var found = Set<Int32>()
        for skip in -1..<scalars.count {
            let key = Self.hash(scalars, skipping: skip)
            var lo = 0, hi = deleteKeys.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if deleteKeys[mid] < key { lo = mid + 1 } else { hi = mid }
            }
            while lo < deleteKeys.count, deleteKeys[lo] == key {
                found.insert(deleteIds[lo])
                lo += 1
            }
        }
        return found
    }

    /// FNV-1a over the scalars, leaving out index `skip` (-1 keeps all).
    private static func hash(_ scalars: [UInt32], skipping skip: Int) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for (i, v) in scalars.enumerated() where i != skip {
            h ^= UInt64(v)
            h &*= 0x100_0000_01b3
        }
        return h
    }
}
