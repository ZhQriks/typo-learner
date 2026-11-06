import Foundation

public struct DayPoint: Identifiable, Sendable {
    public var id: String { day }
    public let day: String
    public let date: Date
    public let stat: DayStat
}

public struct PairRow: Identifiable, Sendable {
    public let id: String
    public let typed: String
    public let intended: String
    public let stat: PairStat
}

public struct PatternRow: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let count: Int
    public let lang: Lang?
}

/// Read-only copy of what the dashboard shows.
public struct Snapshot: Sendable {
    public var settings = Settings()
    public var today = DayStat()
    public var total = DayStat()
    public var days: [DayPoint] = []
    public var log: [LogEntry] = []
    public var pairs: [PairRow] = []
    public var patterns: [PatternRow] = []
    /// Mistakes involving each key.
    public var keyErrors: [Character: Int] = [:]
    public var totalChars = 0
    public var totalErrors = 0
    public var vocabulary = 0
    public var yourWords = 0
    public var protectedCount = 0

    public init() {}
}

extension Engine {
    public func snapshot() -> Snapshot {
        var s = Snapshot()
        s.settings = model.settings
        s.today = model.days[dayKey(now())] ?? DayStat()
        s.total = model.days.values.reduce(DayStat(), +)
        s.days = model.days
            .compactMap { key, stat in Self.dayFormatter.date(from: key).map { DayPoint(day: key, date: $0, stat: stat) } }
            .sorted { $0.date < $1.date }
            .suffix(30)
        s.log = model.log.reversed()
        s.pairs = model.pairs
            .compactMap { key, stat -> PairRow? in
                let parts = key.split(separator: "\u{1}", omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return PairRow(id: key, typed: String(parts[0]), intended: String(parts[1]), stat: stat)
            }
            .sorted { weight($0.stat) > weight($1.stat) }
            .prefix(100)
            .map { $0 }
        s.patterns = model.ops
            .sorted { $0.value > $1.value }
            .prefix(40)
            .map { PatternRow(id: $0.key, label: Self.describe($0.key), count: $0.value, lang: Self.language(ofKey: $0.key)) }
        for (key, count) in model.ops {
            for c in key.dropFirst(2).prefix(key.hasPrefix("t:") ? 2 : 1) {
                s.keyErrors[c, default: 0] += count
            }
        }
        s.totalChars = model.totalChars
        s.totalErrors = model.totalErrors
        s.vocabulary = model.unigrams.count
        s.yourWords = model.userWords.count
        s.protectedCount = model.protectedWords.count
        return s
    }

    private func weight(_ stat: PairStat) -> Int {
        stat.fixedByYou + stat.applied + stat.confirmed + stat.rejected
    }

    static func describe(_ key: String) -> String {
        let chars = Array(key.dropFirst(2))
        switch key.prefix(2) {
        case "s:" where chars.count == 2: return "\(chars[1]) instead of \(chars[0])"
        case "o:" where chars.count == 1: return "dropped \(chars[0])"
        case "i:" where chars.count == 1: return "extra \(chars[0])"
        case "t:" where chars.count == 2: return "\(chars[1])\(chars[0]) instead of \(chars[0])\(chars[1])"
        default: return key
        }
    }

    static func language(ofKey key: String) -> Lang? {
        Keyboard.language(of: String(key.dropFirst(2)))
    }
}
