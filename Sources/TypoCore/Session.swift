import Foundation

public enum KeyEvent: Equatable, Sendable {
    /// Part of a word: letters, digits, apostrophes, hyphens.
    case character(Character)
    /// Space or punctuation between words.
    case separator(Character)
    /// Return or Tab. Never corrected: the text may already be sent.
    case lineBreak
    case backspace
    /// The cursor may have moved (click, arrow, shortcut, app switch).
    case reset
}

/// Text edit for the app to perform: press Delete `deleteCount` times, then type `text`.
public struct Replacement: Equatable, Sendable {
    public let deleteCount: Int
    public let text: String
}

/// Follows the word being typed and the two before it, and decides what to learn and fix.
/// These words are the only text ever held; older text is dropped as soon as it leaves.
public final class Session {
    public let engine: Engine
    static let correctingSeparators: Set<Character> = [" ", ",", ".", "!", "?", ";", ":"]

    private struct Word {
        var text: String
        /// Separators typed after the word, so undo can retype them.
        var trailing: String
        var before: String?
        var sentenceStart: Bool
        /// Up to two words before this one, oldest first, or `NGrams.start` at a sentence start.
        var context: [String]
        var correction: (original: String, replacement: String)?
        var suggestion: String?
        var logID: UUID?
    }

    private var previous: Word?
    private var current = ""
    /// The word as it was at its first backspace, for learning mid-word fixes.
    private var snapshot: String?
    /// The previous word, when you backspaced into it to fix it.
    private var reopened: Word?
    /// The word was just restored by undo; leave it alone.
    private var restored = false
    private var justCorrected = false
    /// Return was the last thing pressed, so the next word starts a line.
    private var atLineStart = false

    public init(engine: Engine) {
        self.engine = engine
    }

    public func handle(_ event: KeyEvent) -> Replacement? {
        guard engine.model.settings.mode != .off else {
            forget()
            return nil
        }
        if event != .backspace { justCorrected = false }
        switch event {
        case let .character(c):
            current.append(c)
        case let .separator(c):
            return finishWord(separator: c)
        case .lineBreak:
            _ = finishWord(separator: "\n")
            commitAll()
            atLineStart = true
        case .backspace:
            return backspace()
        case .reset:
            commitAll()
        }
        return nil
    }

    /// Restores the word as typed before the last correction, if it is still within reach.
    public func undoLastCorrection() -> Replacement? {
        guard var word = previous, let correction = word.correction else { return nil }
        let tail = word.trailing + current
        engine.recordUndo(typed: correction.original, replacement: correction.replacement, logID: word.logID)
        word.text = correction.original
        word.correction = nil
        previous = word
        justCorrected = false
        return Replacement(deleteCount: correction.replacement.count + tail.count, text: correction.original + tail)
    }

    public func reset() {
        commitAll()
    }

    // MARK: - Private

    private func finishWord(separator: Character) -> Replacement? {
        guard !current.isEmpty else {
            previous?.trailing.append(separator)
            return nil
        }
        let text = current
        let edited = snapshot != nil || reopened != nil || restored

        let before: String?
        let sentenceStart: Bool
        let context: [String]
        if let reopened {
            before = reopened.before
            sentenceStart = reopened.sentenceStart
            context = reopened.context
        } else if let previous {
            before = previous.trailing.allSatisfy { $0 == " " || $0 == "," } ? previous.text : nil
            sentenceStart = previous.trailing.contains { ".!?\n".contains($0) }
            context = sentenceStart ? [NGrams.start] : before.map { Array((previous.context + [$0]).suffix(2)) } ?? []
            engine.commit(previous.text, context: previous.context)
        } else {
            before = nil
            sentenceStart = atLineStart
            context = atLineStart ? [NGrams.start] : []
        }
        atLineStart = false

        if let reopened {
            learnFromReopened(reopened, final: text)
        } else if let snapshot {
            // As long as the final word means you had typed all of it ("wiht" → "with"), it is a whole-word fix.
            let wholeWord = snapshot.count >= text.count
            if wholeWord {
                // Judge what it would have done, before the fix teaches it anything.
                engine.judgeOwnFix(typed: snapshot, final: text, before: before, sentenceStart: sentenceStart)
            }
            engine.learnEdit(typed: snapshot, final: text, wholeWord: wholeWord)
        }
        // A reopened or restored word was already scored the first time round.
        if reopened == nil, !restored { engine.scorePrediction(of: text, context: context) }
        engine.noteWordTyped(text)
        current = ""
        snapshot = nil
        reopened = nil
        restored = false

        var word = Word(
            text: text, trailing: String(separator), before: before, sentenceStart: sentenceStart, context: context
        )
        previous = word
        guard !edited, Self.correctingSeparators.contains(separator),
              let suggestion = engine.suggest(text, before: before, sentenceStart: sentenceStart),
              engine.clears(suggestion) else { return nil }

        if engine.model.settings.mode == .shadow {
            word.suggestion = suggestion.replacement
            word.logID = engine.log(suggestion, before: before, status: .suggested)
            previous = word
            return nil
        }
        word.correction = (text, suggestion.replacement)
        word.text = suggestion.replacement
        word.logID = engine.log(suggestion, before: before, status: .applied)
        previous = word
        justCorrected = true
        return Replacement(deleteCount: text.count + 1, text: suggestion.replacement + String(separator))
    }

    private func learnFromReopened(_ word: Word, final: String) {
        if let correction = word.correction {
            // You went back and changed our fix.
            guard final != correction.replacement else { return }
            engine.recordUndo(typed: correction.original, replacement: correction.replacement, logID: word.logID)
            if final != correction.original {
                engine.learnEdit(typed: correction.original, final: final, wholeWord: true)
            }
        } else if final != word.text {
            if let suggestion = word.suggestion {
                if final == suggestion {
                    engine.recordSelfFix(logID: word.logID)
                } else if engine.isFix(word.text, final) {
                    engine.recordDiffered(logID: word.logID)
                }
            }
            engine.learnEdit(typed: word.text, final: final, wholeWord: true)
        }
    }

    private func backspace() -> Replacement? {
        // Backspace right after a fix means "no": put back what you typed.
        if justCorrected, let word = previous, let correction = word.correction,
           current.isEmpty, word.trailing.count == 1 {
            justCorrected = false
            engine.recordUndo(typed: correction.original, replacement: correction.replacement, logID: word.logID)
            previous = nil
            current = correction.original
            restored = true
            return Replacement(deleteCount: correction.replacement.count, text: correction.original)
        }
        justCorrected = false
        if !current.isEmpty {
            if snapshot == nil, reopened == nil, !restored { snapshot = current }
            current.removeLast()
        } else if var word = previous {
            word.trailing.removeLast()
            if word.trailing.isEmpty {
                reopened = word
                current = word.text
                snapshot = nil
                previous = nil
            } else {
                previous = word
            }
        }
        return nil
    }

    private func commitAll() {
        if let previous { engine.commit(previous.text, context: previous.context) }
        forget()
    }

    private func forget() {
        previous = nil
        current = ""
        snapshot = nil
        reopened = nil
        restored = false
        justCorrected = false
        atLineStart = false
    }
}
