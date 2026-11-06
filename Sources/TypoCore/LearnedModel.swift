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

    public init() {}

    /// Suggestions whose outcome is known.
    public var judged: Int { applied + markedRight + markedWrong + selfFixed }
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
        return s
    }
}

public struct LogEntry: Codable, Identifiable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case suggested, applied, undone, right, wrong, selfFixed
    }

    public var id = UUID()
    public var date: Date
    public var before: String?
    public var typed: String
    public var suggestion: String
    public var confidence: Double
    public var status: Status
}

/// Everything the app learns. Holds statistics only, never running text; persisted encrypted by the app.
public struct LearnedModel: Codable, Sendable {
    public var version = 1
    /// Per-install salt for hashing words that are not in the dictionary.
    public var salt: Data
    public var totalChars = 0
    public var totalErrors = 0
    /// Count of each personal mistake, keyed by `EditOp.key`.
    public var ops: [String: Int] = [:]
    /// Dictionary words you typed and kept.
    public var unigrams: [String: Int] = [:]
    public var unigramTotal = 0
    /// "previous word" + " " + "word" counts, dictionary words only.
    public var bigrams: [String: Int] = [:]
    /// typo + "\u{1}" + intended word.
    public var pairs: [String: PairStat] = [:]
    /// Salted hashes of non-dictionary words you keep typing (names, slang).
    public var userWords: [String: Int] = [:]
    public var protectedWords: Set<String> = []
    public var days: [String: DayStat] = [:]
    public var log: [LogEntry] = []
    public var settings = Settings()

    public init(salt: Data = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })) {
        self.salt = salt
    }

    public static func pairKey(_ typed: String, _ intended: String) -> String {
        typed + "\u{1}" + intended
    }
}
