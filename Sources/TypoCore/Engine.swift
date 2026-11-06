import CryptoKit
import Foundation

public struct Suggestion: Equatable, Sendable {
    public let typed: String
    /// Replacement with the typed word's capitalization.
    public let replacement: String
    /// Posterior probability that you meant `replacement`.
    public let confidence: Double
    /// The typed word is itself a dictionary word ("form" vs "from").
    public let typedIsWord: Bool
}

/// Noisy-channel corrector: P(meant word | typed) ∝ P(typed | meant, your mistakes) × P(meant | previous word).
/// Not thread-safe; the app serializes access.
public final class Engine {
    public var model: LearnedModel
    public let lexicons: [Lang: Lexicon]
    /// Set on every change so the app knows when to save.
    public var dirty = false
    public var now: () -> Date = Date.init
    /// Second opinion from a full system dictionary (the app uses the on-device macOS spell checker).
    /// A word it knows is never changed. Only asked when a fix is likely, so it costs nothing per keystroke.
    public var isRealWord: ((String, Lang) -> Bool)?

    static let logLimit = 300
    static let bigramLimit = 200_000
    /// Rough number of distinct mistakes a person makes, used to judge what is above your average.
    static let typicalMistakeKinds = 300.0

    public init(model: LearnedModel, lexicons: [Lang: Lexicon]) {
        self.model = model
        self.lexicons = lexicons
    }

    // MARK: - Scoring

    public func suggest(_ typed: String, before: String?, sentenceStart: Bool) -> Suggestion? {
        guard (3...24).contains(typed.count), let casing = Casing(typed) else { return nil }
        let word = Keyboard.normalize(typed)
        guard let lang = Keyboard.language(of: word), let lexicon = lexicons[lang] else { return nil }
        let hash = hashWord(word)
        guard !model.protectedWords.contains(hash) else { return nil }
        let kept = model.userWords[hash] ?? 0
        guard kept < 3 else { return nil }

        let previous = before.map(Keyboard.normalize)
        let knownId = lexicon.id(of: word)
        var identity: Double
        if let knownId {
            identity = languageProbability(knownId, in: lexicon, after: previous)
        } else {
            // Mass for "you meant exactly this unfamiliar word", e.g. a name or slang.
            identity = Self.unknownWordMass(length: word.count)
            if casing == .capitalized, !sentenceStart { identity *= 100 } // likely a proper noun
        }
        identity *= 1 + 10 * Double(kept)

        let typedChars = Array(word)
        var total = identity
        var best: (id: Int32, score: Double)?
        for id in lexicon.candidates(for: word) where id != knownId {
            let candidate = lexicon.characters(id)
            guard candidate.count >= 2,
                  let ops = EditDistance.align(intended: candidate, typed: typedChars),
                  !ops.isEmpty else { continue }
            var score = languageProbability(id, in: lexicon, after: previous)
            for op in ops { score *= mistakeProbability(op) }
            score *= pairFactor(typed: word, intended: lexicon.words[Int(id)])
            total += score
            if score > (best?.score ?? 0) { best = (id, score) }
        }
        guard let best, total > 0 else { return nil }
        if knownId == nil, best.score / total >= 0.5, isRealWord?(word, lang) == true { return nil }
        return Suggestion(
            typed: typed,
            replacement: casing.apply(lexicon.words[Int(best.id)]),
            confidence: best.score / total,
            typedIsWord: knownId != nil
        )
    }

    static func unknownWordMass(length: Int) -> Double {
        switch length {
        case ...3: return 3e-8
        case 4: return 3e-9
        default: return 1e-9
        }
    }

    func languageProbability(_ id: Int32, in lexicon: Lexicon, after previous: String?) -> Double {
        let word = lexicon.words[Int(id)]
        var unigram = lexicon.probability(id)
        let total = Double(model.unigramTotal)
        if total > 0 {
            // Lean on your own vocabulary more as it grows, up to half.
            let weight = min(0.5, total / (total + 50_000))
            unigram = (1 - weight) * unigram + weight * Double(model.unigrams[word] ?? 0) / total
        }
        guard let previous, let previousCount = model.unigrams[previous], previousCount > 0 else { return unigram }
        let pair = Double(model.bigrams[previous + " " + word] ?? 0)
        return (pair + 10 * unigram) / (Double(previousCount) + 10)
    }

    func mistakeProbability(_ op: EditOp) -> Double {
        let average = Double(model.totalErrors) / Self.typicalMistakeKinds
        let count = Double(model.ops[op.key] ?? 0)
        let boost = min(10, max(0.3, (count + 2) / (average + 2)))
        return op.prior * boost
    }

    func pairFactor(typed: String, intended: String) -> Double {
        guard let stat = model.pairs[LearnedModel.pairKey(typed, intended)] else { return 1 }
        let good = min(20, 1 + Double(stat.fixedByYou + stat.confirmed))
        return good / (1 + 50 * Double(stat.rejected))
    }

    // MARK: - Learning

    /// You replaced `typed` with `final` yourself. `wholeWord` is false when the fix happened mid-word,
    /// so only the part typed before the first backspace is compared.
    public func learnEdit(typed: String, final: String, wholeWord: Bool) {
        let t = Keyboard.normalize(typed), f = Keyboard.normalize(final)
        guard t != f, let lang = Keyboard.language(of: f), Keyboard.language(of: t) == lang else { return }
        let intended = wholeWord ? Array(f) : Array(f.prefix(t.count))
        guard intended.count >= 2,
              let ops = EditDistance.align(intended: intended, typed: Array(t)),
              !ops.isEmpty else { return }
        for op in ops { model.ops[op.key, default: 0] += 1 }
        model.totalErrors += ops.count
        if wholeWord, lexicons[lang]?.id(of: f) != nil {
            model.pairs[LearnedModel.pairKey(t, f), default: PairStat()].fixedByYou += 1
        }
        dirty = true
    }

    public func noteWordTyped(_ word: String) {
        model.totalChars += word.count + 1
        model.days[dayKey(now()), default: DayStat()].words += 1
        dirty = true
    }

    /// A word left the editable window: count it as part of your vocabulary.
    public func commit(_ word: String, before: String?) {
        let w = Keyboard.normalize(word)
        guard let lang = Keyboard.language(of: w), let lexicon = lexicons[lang] else { return }
        if lexicon.id(of: w) != nil {
            model.unigrams[w, default: 0] += 1
            model.unigramTotal += 1
            if let b = before.map(Keyboard.normalize), lexicon.id(of: b) != nil {
                model.bigrams[b + " " + w, default: 0] += 1
                if model.bigrams.count > Self.bigramLimit {
                    model.bigrams = model.bigrams.filter { $0.value > 1 }
                }
            }
        } else if w.count >= 2 {
            // Only counts as yours when it does not look like a typo of a known word.
            if (suggest(w, before: nil, sentenceStart: true)?.confidence ?? 0) < 0.5 {
                model.userWords[hashWord(w), default: 0] += 1
            }
        }
        dirty = true
    }

    @discardableResult
    public func log(_ s: Suggestion, before: String?, status: LogEntry.Status) -> UUID {
        let entry = LogEntry(
            date: now(), before: before, typed: s.typed, suggestion: s.replacement,
            confidence: s.confidence, status: status
        )
        model.log.append(entry)
        if model.log.count > Self.logLimit { model.log.removeFirst(model.log.count - Self.logLimit) }
        let key = dayKey(entry.date)
        if status == .applied {
            model.days[key, default: DayStat()].applied += 1
            model.pairs[pairKey(entry), default: PairStat()].applied += 1
        } else {
            model.days[key, default: DayStat()].suggested += 1
        }
        dirty = true
        return entry.id
    }

    /// You undid an applied correction.
    public func recordUndo(typed: String, replacement: String, logID: UUID?) {
        reject(typed: typed, replacement: replacement)
        model.days[dayKey(now()), default: DayStat()].undone += 1
        setStatus(.undone, for: logID)
    }

    /// You fixed a shadow-mode typo exactly the way it suggested.
    public func recordSelfFix(logID: UUID?) {
        guard let logID, let i = model.log.firstIndex(where: { $0.id == logID }),
              model.log[i].status == .suggested else { return }
        model.log[i].status = .selfFixed
        model.days[dayKey(model.log[i].date), default: DayStat()].selfFixed += 1
        dirty = true
    }

    /// Feedback from the dashboard on a logged suggestion.
    public func mark(_ id: UUID, right: Bool) {
        guard let i = model.log.firstIndex(where: { $0.id == id }) else { return }
        let entry = model.log[i]
        let key = dayKey(entry.date)
        switch (entry.status, right) {
        case (.suggested, true):
            model.log[i].status = .right
            model.days[key, default: DayStat()].markedRight += 1
            model.pairs[pairKey(entry), default: PairStat()].confirmed += 1
        case (.suggested, false):
            model.log[i].status = .wrong
            model.days[key, default: DayStat()].markedWrong += 1
            reject(typed: entry.typed, replacement: entry.suggestion)
        case (.applied, false):
            model.log[i].status = .undone
            model.days[key, default: DayStat()].undone += 1
            reject(typed: entry.typed, replacement: entry.suggestion)
        default:
            return
        }
        dirty = true
    }

    public func protect(_ word: String) {
        let w = Keyboard.normalize(word.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !w.isEmpty else { return }
        model.protectedWords.insert(hashWord(w))
        dirty = true
    }

    public func clearLog() {
        model.log.removeAll()
        dirty = true
    }

    /// Forget everything learned, keeping settings.
    public func eraseLearning() {
        let settings = model.settings
        model = LearnedModel()
        model.settings = settings
        dirty = true
    }

    private func reject(typed: String, replacement: String) {
        let t = Keyboard.normalize(typed)
        model.pairs[LearnedModel.pairKey(t, Keyboard.normalize(replacement)), default: PairStat()].rejected += 1
        model.userWords[hashWord(t), default: 0] += 1
        dirty = true
    }

    private func setStatus(_ status: LogEntry.Status, for id: UUID?) {
        guard let id, let i = model.log.firstIndex(where: { $0.id == id }) else { return }
        model.log[i].status = status
    }

    private func pairKey(_ entry: LogEntry) -> String {
        LearnedModel.pairKey(Keyboard.normalize(entry.typed), Keyboard.normalize(entry.suggestion))
    }

    /// Salted hash so words outside the dictionary (names, slang) are never stored readable.
    func hashWord(_ word: String) -> String {
        var hasher = SHA256()
        hasher.update(data: model.salt)
        hasher.update(data: Data(word.utf8))
        return hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func dayKey(_ date: Date) -> String { Self.dayFormatter.string(from: date) }
}

/// Capitalization patterns safe to reproduce; anything else (ALL CAPS, iPhone) is left alone.
enum Casing {
    case lower, capitalized

    init?(_ s: String) {
        if s == s.lowercased() {
            self = .lower
        } else if let first = s.first, String(first) == String(first).uppercased(),
                  String(s.dropFirst()) == String(s.dropFirst()).lowercased() {
            self = .capitalized
        } else {
            return nil
        }
    }

    func apply(_ word: String) -> String {
        self == .lower ? word : word.prefix(1).uppercased() + word.dropFirst()
    }
}
