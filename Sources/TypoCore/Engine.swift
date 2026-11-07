import CryptoKit
import Foundation

public struct Suggestion: Equatable, Sendable {
    public let typed: String
    /// Replacement with the typed word's capitalization. Two words when a space was missed ("u can").
    public let replacement: String
    /// Posterior probability that you meant `replacement`.
    public let confidence: Double
    /// The typed word is itself a real word ("form" vs "from").
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
    /// Bundle ID of the app being typed in, for per-app phrase counts.
    public var app: String?

    static let logLimit = 300
    public static let ngramLimit = 300_000
    static let appNgramLimit = 30_000
    /// Rough number of distinct mistakes a person makes, used to judge what is above your average.
    static let typicalMistakeKinds = 300.0
    /// The word lists come from subtitles and hold junk ("cann", "sith"). Past this rank, a word the
    /// system spell checker rejects and you never typed is not trusted. Above it, slang like "dont" stays.
    static let trustedRank: Int32 = 10_000
    /// Fast typists often miss the space between two words.
    static let missingSpacePrior = 0.004
    static let singleLetterWords: Set<String> = ["a", "i", "u", "я", "в", "и", "с", "к", "о", "у", "а"]

    public init(model: LearnedModel, lexicons: [Lang: Lexicon]) {
        self.model = model
        self.lexicons = lexicons
    }

    // MARK: - Scoring

    private struct Candidate {
        let text: String
        let id: Int32?
        let score: Double
    }

    public func suggest(_ typed: String, before: String?, sentenceStart: Bool) -> Suggestion? {
        guard (3...24).contains(typed.count), let casing = Casing(typed) else { return nil }
        let word = Keyboard.normalize(typed)
        guard let lang = Keyboard.language(of: word), let lexicon = lexicons[lang] else { return nil }
        let hash = hashWord(word)
        guard !model.protectedWords.contains(hash) else { return nil }
        let kept = model.userWords[word] ?? model.legacyUserWordHashes[hash] ?? 0
        guard kept < 3 else { return nil }

        let previous = before.map(Keyboard.normalize)
        // Junk from the word list ("inthe") counts as unknown, so it can be fixed.
        let knownId = lexicon.id(of: word).flatMap { isJunk($0, in: lexicon) ? nil : $0 }
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
        var candidates: [Candidate] = []
        for id in lexicon.candidates(for: word) where id != knownId {
            let chars = lexicon.characters(id)
            guard chars.count >= 2,
                  let ops = EditDistance.align(intended: chars, typed: typedChars),
                  !ops.isEmpty else { continue }
            var score = languageProbability(id, in: lexicon, after: previous)
            for op in ops { score *= mistakeProbability(op) }
            score *= pairFactor(typed: word, intended: lexicon.words[Int(id)])
            candidates.append(Candidate(text: lexicon.words[Int(id)], id: id, score: score))
        }
        if knownId == nil { candidates += splits(of: typedChars, in: lexicon, after: previous) }
        var total = identity + candidates.reduce(0) { $0 + $1.score }
        candidates.sort { $0.score > $1.score }
        // Junk from the word list is never suggested; its mass goes away with it.
        while let top = candidates.first, top.score / total >= 0.5, let id = top.id, isJunk(id, in: lexicon) {
            total -= top.score
            candidates.removeFirst()
        }
        guard let best = candidates.first, total > 0 else { return nil }
        let confidence = best.score / total
        if knownId == nil, confidence >= 0.5, isRealWord?(word, lang) == true { return nil }
        let typedIsWord = knownId != nil
        if typedIsWord {
            // One real word for another only for swaps you have made yourself.
            let stat = model.pairs[LearnedModel.pairKey(word, best.text)]
            guard (stat?.fixedByYou ?? 0) + (stat?.confirmed ?? 0) >= 2 else { return nil }
        }
        return Suggestion(
            typed: typed,
            replacement: casing.apply(best.text),
            confidence: confidence,
            typedIsWord: typedIsWord
        )
    }

    /// Whether a suggestion is sure enough to apply or log.
    public func clears(_ s: Suggestion) -> Bool {
        let threshold = model.settings.threshold
        // Replacing one real word with another needs near certainty.
        return s.confidence >= (s.typedIsWord ? max(threshold, 0.99) : threshold)
    }

    static func unknownWordMass(length: Int) -> Double {
        switch length {
        case ...3: return 3e-8
        case 4: return 3e-9
        default: return 1e-9
        }
    }

    /// Two words typed without the space between them ("amonth" → "a month").
    private func splits(of chars: [Character], in lexicon: Lexicon, after previous: String?) -> [Candidate] {
        var found: [Candidate] = []
        for i in 1..<chars.count {
            let left = String(chars[..<i]), right = String(chars[i...])
            guard isSplitPart(left, in: lexicon), isSplitPart(right, in: lexicon) else { continue }
            let text = left + " " + right
            var score = tokenProbability(left, in: lexicon, after: previous)
                * tokenProbability(right, in: lexicon, after: left)
            score *= Self.missingSpacePrior * boost(EditOp.omit(" ", doubled: false).key)
            score *= pairFactor(typed: String(chars), intended: text)
            found.append(Candidate(text: text, id: nil, score: score))
        }
        return found
    }

    private func isSplitPart(_ word: String, in lexicon: Lexicon) -> Bool {
        let yours = (model.userWords[word] ?? 0) >= 3 || model.unigrams[word] != nil
        if word.count == 1 { return Self.singleLetterWords.contains(word) && (yours || lexicon.id(of: word) != nil) }
        if let id = lexicon.id(of: word), id < Self.trustedRank { return true }
        return yours
    }

    /// A low-ranked list word that the system dictionary rejects and you never typed.
    private func isJunk(_ id: Int32, in lexicon: Lexicon) -> Bool {
        guard id >= Self.trustedRank else { return false }
        let word = lexicon.words[Int(id)]
        guard model.unigrams[word] == nil else { return false }
        return isRealWord?(word, lexicon.lang) == false
    }

    func languageProbability(_ id: Int32, in lexicon: Lexicon, after previous: String?) -> Double {
        let word = lexicon.words[Int(id)]
        let unigram = mixedUnigram(lexical: lexicon.probability(id), personal: model.unigrams[word] ?? 0)
        return contextual(word, unigram: unigram, after: previous)
    }

    /// Same as `languageProbability`, for a word that may be one of your own rather than a list word.
    private func tokenProbability(_ word: String, in lexicon: Lexicon, after previous: String?) -> Double {
        let lexical = lexicon.id(of: word).map(lexicon.probability) ?? 0
        return contextual(word, unigram: mixedUnigram(lexical: lexical, personal: personalCount(word)), after: previous)
    }

    private func mixedUnigram(lexical: Double, personal: Int) -> Double {
        let total = Double(model.unigramTotal)
        guard total > 0 else { return lexical }
        // Lean on your own vocabulary more as it grows, up to half.
        let weight = min(0.5, total / (total + 50_000))
        return (1 - weight) * lexical + weight * Double(personal) / total
    }

    private func contextual(_ word: String, unigram: Double, after previous: String?) -> Double {
        guard let previous else { return unigram }
        let previousCount = personalCount(previous)
        guard previousCount > 0 else { return unigram }
        let pair = Double(model.ngrams.count(previous, word))
        return (pair + 10 * unigram) / (Double(previousCount) + 10)
    }

    private func personalCount(_ word: String) -> Int {
        model.unigrams[word] ?? model.userWords[word] ?? 0
    }

    func mistakeProbability(_ op: EditOp) -> Double {
        op.prior * boost(op.key)
    }

    /// How much more often than average you make this mistake.
    private func boost(_ key: String) -> Double {
        let average = Double(model.totalErrors) / Self.typicalMistakeKinds
        let count = Double(model.ops[key] ?? 0)
        return min(10, max(0.3, (count + 2) / (average + 2)))
    }

    func pairFactor(typed: String, intended: String) -> Double {
        guard let stat = model.pairs[LearnedModel.pairKey(typed, intended)] else { return 1 }
        let good = min(20, 1 + Double(stat.fixedByYou + stat.confirmed))
        return good / (1 + 50 * Double(stat.rejected))
    }

    // MARK: - Prediction (shadow only for now)

    /// Most likely next words after `context` (oldest first), from your own phrases.
    public func predictNext(after context: [String], limit: Int) -> [String] {
        guard let last = context.last else { return [] }
        var scores: [String: Double] = [:]
        func blend(_ followers: [String: Int], weight: Double) {
            let total = Double(followers.values.reduce(0, +))
            guard total > 0 else { return }
            for (word, count) in followers { scores[word, default: 0] += weight * Double(count) / total }
        }
        if context.count >= 2 { blend(model.ngrams.followers(context.suffix(2).joined(separator: " ")), weight: 0.6) }
        blend(model.ngrams.followers(last), weight: 0.4)
        return scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }

    /// Keystrokes a completion from your vocabulary would have saved on `word`: it shows up once the
    /// letters typed rule out every word you use more, and one key accepts it.
    func completionSavings(_ word: String, after previous: String?) -> Int {
        let chars = Array(word)
        let own = personalCount(word)
        guard chars.count >= 3, own > 0 else { return 0 }
        func score(_ candidate: String, _ count: Int) -> Double {
            Double(count) + 3 * Double(previous.map { model.ngrams.count($0, candidate) } ?? 0)
        }
        let target = score(word, own)
        var needed = 1
        func consider(_ candidate: String, _ count: Int) {
            guard candidate != word, candidate.first == chars[0], score(candidate, count) >= target else { return }
            var shared = 0
            for (a, b) in zip(candidate, chars) {
                guard a == b else { break }
                shared += 1
            }
            needed = max(needed, min(shared, candidate.count - 1) + 1)
        }
        for (candidate, count) in model.unigrams { consider(candidate, count) }
        for (candidate, count) in model.userWords { consider(candidate, count) }
        return max(0, chars.count - needed - 1)
    }

    /// Would it have predicted `word` from the words before it? Only the counts are kept.
    public func scorePrediction(of word: String, context: [String]) {
        let w = Keyboard.normalize(word)
        guard Keyboard.language(of: w) != nil else { return }
        let tokens = context.map(Keyboard.normalize)
        let key = dayKey(now())
        var day = model.days[key, default: DayStat()]
        day.letters += w.count
        day.completionSaved += completionSavings(w, after: tokens.last.flatMap { $0 == NGrams.start ? nil : $0 })
        if !tokens.isEmpty {
            let guesses = predictNext(after: tokens, limit: 3)
            day.predicted += 1
            if guesses.first == w { day.nextTop1 += 1 }
            if guesses.contains(w) { day.nextTop3 += 1 }
        }
        model.days[key] = day
        dirty = true
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
        // A real word changed into another is usually rewording ("what" → "why"), not a typo.
        // Learn it only when it looks like a finger slip.
        if isWord(t, lang), !(ops.count == 1 && ops[0].isSlip) { return }
        for op in ops { model.ops[op.key, default: 0] += 1 }
        model.totalErrors += ops.count
        if wholeWord, lexicons[lang]?.id(of: f) != nil {
            model.pairs[LearnedModel.pairKey(t, f), default: PairStat()].fixedByYou += 1
        }
        dirty = true
    }

    private func isWord(_ word: String, _ lang: Lang) -> Bool {
        if let lexicon = lexicons[lang], let id = lexicon.id(of: word) { return !isJunk(id, in: lexicon) }
        return isRealWord?(word, lang) ?? false
    }

    public func noteWordTyped(_ word: String) {
        model.totalChars += word.count + 1
        model.days[dayKey(now()), default: DayStat()].words += 1
        dirty = true
    }

    /// A word left the editable window: count it as part of your vocabulary and phrases.
    /// `context` holds up to two words before it, oldest first, or `NGrams.start` at a sentence start.
    public func commit(_ word: String, context: [String]) {
        let w = Keyboard.normalize(word)
        guard let lang = Keyboard.language(of: w), let lexicon = lexicons[lang] else { return }
        dirty = true
        if lexicon.id(of: w) != nil {
            model.unigrams[w, default: 0] += 1
            model.unigramTotal += 1
        } else if (suggest(w, before: nil, sentenceStart: true)?.confidence ?? 0) < 0.5 {
            // Only counts as yours when it does not look like a typo of a known word.
            addUserWord(w)
        } else {
            return
        }
        let tokens = context.map(Keyboard.normalize)
        guard let last = tokens.last, isVocabulary(last) else { return }
        model.ngrams.add(last, w, limit: Self.ngramLimit)
        if tokens.count >= 2, isVocabulary(tokens[tokens.count - 2]) {
            model.ngrams.add(tokens.suffix(2).joined(separator: " "), w, limit: Self.ngramLimit)
        }
        if let app {
            model.appNgrams[app, default: NGrams()].add(last, w, limit: Self.appNgramLimit)
        }
    }

    private func isVocabulary(_ token: String) -> Bool {
        token == NGrams.start || model.unigrams[token] != nil || model.userWords[token] != nil
    }

    private func addUserWord(_ word: String) {
        let legacy = model.legacyUserWordHashes.removeValue(forKey: hashWord(word)) ?? 0
        model.userWords[word, default: 0] += 1 + legacy
    }

    private func removeUserWord(_ word: String) {
        if let count = model.userWords[word] {
            model.userWords[word] = count > 1 ? count - 1 : nil
        } else if let count = model.legacyUserWordHashes[hashWord(word)] {
            model.legacyUserWordHashes[hashWord(word)] = count > 1 ? count - 1 : nil
        }
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
        switch status {
        case .applied:
            model.days[key, default: DayStat()].applied += 1
            model.pairs[pairKey(entry), default: PairStat()].applied += 1
        case .selfFixed:
            model.days[key, default: DayStat()].suggested += 1
            model.days[key, default: DayStat()].selfFixed += 1
        case .differed:
            model.days[key, default: DayStat()].suggested += 1
            model.days[key, default: DayStat()].differed += 1
            model.pairs[pairKey(entry), default: PairStat()].rejected += 1
        default:
            model.days[key, default: DayStat()].suggested += 1
        }
        dirty = true
        return entry.id
    }

    /// You fixed a word yourself before it could (mid-word, before the space).
    /// Judges what it would have done, so accuracy grows without marking anything.
    public func judgeOwnFix(typed: String, final: String, before: String?, sentenceStart: Bool) {
        guard isFix(typed, final),
              let s = suggest(typed, before: before, sentenceStart: sentenceStart), clears(s) else { return }
        let right = Keyboard.normalize(s.replacement) == Keyboard.normalize(final)
        log(s, before: before, status: right ? .selfFixed : .differed)
    }

    /// Close enough to be a fix of the same word, not a different word altogether.
    public func isFix(_ typed: String, _ final: String) -> Bool {
        EditDistance.align(intended: Array(Keyboard.normalize(final)), typed: Array(Keyboard.normalize(typed))) != nil
    }

    /// You undid an applied correction.
    public func recordUndo(typed: String, replacement: String, logID: UUID?) {
        reject(typed: typed, replacement: replacement)
        model.days[dayKey(now()), default: DayStat()].undone += 1
        setStatus(.undone, for: logID)
    }

    /// You fixed a shadow-mode typo exactly the way it suggested.
    public func recordSelfFix(logID: UUID?) {
        guard let i = suggestedEntry(logID) else { return }
        model.log[i].status = .selfFixed
        model.days[dayKey(model.log[i].date), default: DayStat()].selfFixed += 1
        dirty = true
    }

    /// You fixed a shadow-mode typo, but not the way it suggested.
    public func recordDiffered(logID: UUID?) {
        guard let i = suggestedEntry(logID) else { return }
        model.log[i].status = .differed
        model.days[dayKey(model.log[i].date), default: DayStat()].differed += 1
        model.pairs[pairKey(model.log[i]), default: PairStat()].rejected += 1
        dirty = true
    }

    private func suggestedEntry(_ id: UUID?) -> Int? {
        guard let id, let i = model.log.firstIndex(where: { $0.id == id }), model.log[i].status == .suggested else {
            return nil
        }
        return i
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

    /// Takes back a mark (or an undo) and everything it taught.
    public func unmark(_ id: UUID) {
        guard let i = model.log.firstIndex(where: { $0.id == id }) else { return }
        let entry = model.log[i]
        let key = dayKey(entry.date), pair = pairKey(entry)
        func lower(_ value: inout Int) { value = max(0, value - 1) }
        switch entry.status {
        case .right:
            model.log[i].status = .suggested
            lower(&model.days[key, default: DayStat()].markedRight)
            lower(&model.pairs[pair, default: PairStat()].confirmed)
        case .wrong, .undone:
            model.log[i].status = entry.status == .wrong ? .suggested : .applied
            if entry.status == .wrong {
                lower(&model.days[key, default: DayStat()].markedWrong)
            } else {
                lower(&model.days[key, default: DayStat()].undone)
            }
            lower(&model.pairs[pair, default: PairStat()].rejected)
            removeUserWord(Keyboard.normalize(entry.typed))
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
        addUserWord(t)
        dirty = true
    }

    private func setStatus(_ status: LogEntry.Status, for id: UUID?) {
        guard let id, let i = model.log.firstIndex(where: { $0.id == id }) else { return }
        model.log[i].status = status
    }

    private func pairKey(_ entry: LogEntry) -> String {
        LearnedModel.pairKey(Keyboard.normalize(entry.typed), Keyboard.normalize(entry.suggestion))
    }

    /// Salted hash, so protected words are never stored readable.
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
