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

/// Follows the word being typed and the one before it, and decides what to learn and fix.
/// These two words are the only text ever held; older text is dropped as soon as it leaves.
public final class Session {
    public let engine: Engine
    static let correctingSeparators: Set<Character> = [" ", ",", ".", "!", "?", ";", ":"]

    private struct Word {
        var text: String
        /// Separators typed after the word, so undo can retype them.
        var trailing: String
        var before: String?
        var sentenceStart: Bool
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
        if let reopened {
            learnFromReopened(reopened, final: text)
        } else if let snapshot {
            // As long as the final word means you had typed all of it ("wiht" → "with"), it is a whole-word fix.
            engine.learnEdit(typed: snapshot, final: text, wholeWord: snapshot.count >= text.count)
        }

        let before: String?
        let sentenceStart: Bool
        if let reopened {
            before = reopened.before
            sentenceStart = reopened.sentenceStart
        } else if let previous {
            before = previous.trailing.allSatisfy { $0 == " " || $0 == "," } ? previous.text : nil
            sentenceStart = previous.trailing.contains { ".!?\n".contains($0) }
            engine.commit(previous.text, before: previous.before)
        } else {
            before = nil
            sentenceStart = false
        }
        engine.noteWordTyped(text)
        current = ""
        snapshot = nil
        reopened = nil
        restored = false

        var word = Word(text: text, trailing: String(separator), before: before, sentenceStart: sentenceStart)
        previous = word
        guard !edited, Self.correctingSeparators.contains(separator),
              let suggestion = engine.suggest(text, before: before, sentenceStart: sentenceStart) else { return nil }
        let settings = engine.model.settings
        // Replacing one real word with another needs near certainty.
        let required = suggestion.typedIsWord ? max(settings.threshold, 0.99) : settings.threshold
        guard suggestion.confidence >= required else { return nil }

        if settings.mode == .shadow {
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
            engine.learnEdit(typed: word.text, final: final, wholeWord: true)
            if final == word.suggestion { engine.recordSelfFix(logID: word.logID) }
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
        if let previous { engine.commit(previous.text, before: previous.before) }
        forget()
    }

    private func forget() {
        previous = nil
        current = ""
        snapshot = nil
        reopened = nil
        restored = false
        justCorrected = false
    }
}
