import Foundation

public enum Mode: String, Codable, CaseIterable, Sendable {
    /// Not listening at all.
    case off
    /// Learning and logging what it would fix, never touching your text.
    case shadow
    /// Learning and fixing confident typos.
    case active
}

public struct Settings: Codable, Sendable, Equatable {
    public var mode: Mode = .shadow
    /// Minimum posterior probability before a fix is applied or logged.
    public var threshold: Double = 0.95
    public var blockedApps: [String] = Settings.defaultBlockedApps

    public static let defaultBlockedApps = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode",
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords",
    ]

    public init() {}
}

public struct PairStat: Codable, Sendable, Equatable {
    /// You retyped the typo into this word yourself.
    public var fixedByYou = 0
    public var applied = 0
    /// You confirmed a suggestion was right.
    public var confirmed = 0
    /// You undid it or marked it wrong.
    public var rejected = 0

    public init() {}
}

public struct DayStat: Codable, Sendable, Equatable {
    public var words = 0
    public var suggested = 0
    public var applied = 0
    public var undone = 0
    public var markedRight = 0
    public var markedWrong = 0
    public var selfFixed = 0
    /// You fixed a word it was sure about, but to something else.
    public var differed = 0
    /// Shadow word prediction: words that had context to predict from.
    public var predicted = 0
    public var nextTop1 = 0
    public var nextTop3 = 0
    /// Letters typed, and how many of them word completion would have saved.
    public var letters = 0
    public var completionSaved = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        words = try c.value(.words, or: 0)
        suggested = try c.value(.suggested, or: 0)
        applied = try c.value(.applied, or: 0)
        undone = try c.value(.undone, or: 0)
        markedRight = try c.value(.markedRight, or: 0)
        markedWrong = try c.value(.markedWrong, or: 0)
        selfFixed = try c.value(.selfFixed, or: 0)
        differed = try c.value(.differed, or: 0)
        predicted = try c.value(.predicted, or: 0)
        nextTop1 = try c.value(.nextTop1, or: 0)
        nextTop3 = try c.value(.nextTop3, or: 0)
        letters = try c.value(.letters, or: 0)
        completionSaved = try c.value(.completionSaved, or: 0)
    }

    /// Suggestions whose outcome is known.
    public var judged: Int { applied + markedRight + markedWrong + selfFixed + differed }
    public var correct: Int { max(0, applied - undone) + markedRight + selfFixed }
    public var accuracy: Double? { judged > 0 ? Double(correct) / Double(judged) : nil }

    public static func + (a: DayStat, b: DayStat) -> DayStat {
        var s = DayStat()
        s.words = a.words + b.words
        s.suggested = a.suggested + b.suggested
        s.applied = a.applied + b.applied
        s.undone = a.undone + b.undone
        s.markedRight = a.markedRight + b.markedRight
        s.markedWrong = a.markedWrong + b.markedWrong
        s.selfFixed = a.selfFixed + b.selfFixed
        s.differed = a.differed + b.differed
        s.predicted = a.predicted + b.predicted
        s.nextTop1 = a.nextTop1 + b.nextTop1
        s.nextTop3 = a.nextTop3 + b.nextTop3
        s.letters = a.letters + b.letters
        s.completionSaved = a.completionSaved + b.completionSaved
        return s
    }
}

public struct LogEntry: Codable, Identifiable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case suggested, applied, undone, right, wrong, selfFixed, differed
    }

    public var id = UUID()
    public var date: Date
    public var before: String?
    public var typed: String
    public var suggestion: String
    public var confidence: Double
    public var status: Status
}

/// Which word follows which context. A context is one previous word, two ("i dont"), or `NGrams.start`.
public struct NGrams: Codable, Sendable {
    public static let start = "<s>"
    public private(set) var table: [String: [String: Int]] = [:]
    public private(set) var entries = 0

    public init() {}

    public func count(_ context: String, _ word: String) -> Int { table[context]?[word] ?? 0 }
    public func followers(_ context: String) -> [String: Int] { table[context] ?? [:] }

    public mutating func add(_ context: String, _ word: String, count: Int = 1, limit: Int) {
        let old = table[context]?[word] ?? 0
        if old == 0 { entries += 1 }
        table[context, default: [:]][word] = old + count
        if entries > limit { prune(to: limit * 3 / 4) }
    }

    /// Drops the rarest entries until at most `target` are left, so pruning stays rare.
    mutating func prune(to target: Int) {
        var floor = 1
        while entries > target {
            table = table.compactMapValues { words in
                let kept = words.filter { $0.value > floor }
                return kept.isEmpty ? nil : kept
            }
            entries = table.values.reduce(0) { $0 + $1.count }
            floor += 1
        }
    }
}

/// Everything the app learns. Holds statistics only, never running text; persisted encrypted by the app.
public struct LearnedModel: Codable, Sendable {
    public var version = 2
    /// Per-install salt for hashing protected words.
    public var salt: Data
    public var totalChars = 0
    public var totalErrors = 0
    /// Count of each personal mistake, keyed by `EditOp.key`.
    public var ops: [String: Int] = [:]
    /// Dictionary words you typed and kept.
    public var unigrams: [String: Int] = [:]
    public var unigramTotal = 0
    /// Which word you type after which, over dictionary words and your own words.
    public var ngrams = NGrams()
    /// The same, per app (bundle ID) and one word of context, for app-aware prediction later.
    public var appNgrams: [String: NGrams] = [:]
    /// typo + "\u{1}" + intended word.
    public var pairs: [String: PairStat] = [:]
    /// Words outside the dictionary you keep typing (names, slang). Stored readable inside the encrypted file.
    public var userWords: [String: Int] = [:]
    /// Version 1 kept those as salted hashes, which cannot be turned back into words. Moved over as you type them.
    public var legacyUserWordHashes: [String: Int] = [:]
    public var protectedWords: Set<String> = []
    public var days: [String: DayStat] = [:]
    public var log: [LogEntry] = []
    public var settings = Settings()

    public init(salt: Data = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })) {
        self.salt = salt
    }

    private enum LegacyKeys: String, CodingKey { case bigrams }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fileVersion = try c.value(.version, or: 1)
        salt = try c.decode(Data.self, forKey: .salt)
        totalChars = try c.value(.totalChars, or: 0)
        totalErrors = try c.value(.totalErrors, or: 0)
        ops = try c.value(.ops, or: [:])
        unigrams = try c.value(.unigrams, or: [:])
        unigramTotal = try c.value(.unigramTotal, or: 0)
        ngrams = try c.value(.ngrams, or: NGrams())
        appNgrams = try c.value(.appNgrams, or: [:])
        pairs = try c.value(.pairs, or: [:])
        userWords = try c.value(.userWords, or: [:])
        legacyUserWordHashes = try c.value(.legacyUserWordHashes, or: [:])
        protectedWords = try c.value(.protectedWords, or: [])
        days = try c.value(.days, or: [:])
        log = try c.value(.log, or: [])
        settings = try c.value(.settings, or: Settings())
        if fileVersion < 2 {
            // Version 1: flat "previous word" pairs, and hashed user words.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            for (key, count) in try legacy.decodeIfPresent([String: Int].self, forKey: .bigrams) ?? [:] {
                let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                ngrams.add(parts[0], parts[1], count: count, limit: Engine.ngramLimit)
            }
            legacyUserWordHashes.merge(userWords, uniquingKeysWith: +)
            userWords = [:]
        }
        version = 2
    }

    public static func pairKey(_ typed: String, _ intended: String) -> String {
        typed + "\u{1}" + intended
    }
}

extension KeyedDecodingContainer {
    /// A field added in a later version decodes to its default from older files.
    func value<T: Decodable>(_ key: Key, or fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}
