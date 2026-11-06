import AppKit
import XCTest
@testable import TypoCore

final class TypoCoreTests: XCTestCase {
    static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")
    static let lexicons: [Lang: Lexicon] = [
        .en: try! Lexicon.load(lang: .en, from: resources.appendingPathComponent("en_50k.txt")),
        .ru: try! Lexicon.load(lang: .ru, from: resources.appendingPathComponent("ru_50k.txt")),
    ]

    func makeEngine(mode: Mode = .active) -> Engine {
        var model = LearnedModel()
        model.settings.mode = mode
        let engine = Engine(model: model, lexicons: Self.lexicons)
        engine.isRealWord = Self.systemDictionary
        return engine
    }

    /// Same on-device check the app uses.
    static let systemDictionary: (String, Lang) -> Bool = { word, lang in
        NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: lang.rawValue, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        ).location == NSNotFound
    }

    func type(_ text: String, into session: Session) -> [Replacement] {
        var out: [Replacement] = []
        for c in text {
            let event: KeyEvent
            switch c {
            case "⌫": event = .backspace
            case "\n": event = .lineBreak
            default: event = (c.isLetter || c.isNumber || c == "'") ? .character(c) : .separator(c)
            }
            if let r = session.handle(event) { out.append(r) }
        }
        return out
    }

    // MARK: Edit distance

    func testAlignment() {
        XCTAssertEqual(EditDistance.align(intended: Array("the"), typed: Array("teh")), [.transpose("h", "e")])
        XCTAssertEqual(EditDistance.align(intended: Array("the"), typed: Array("thw")),
                       [.substitute(intended: "e", typed: "w")])
        XCTAssertEqual(EditDistance.align(intended: Array("letter"), typed: Array("leter")), [.omit("t", doubled: true)])
        XCTAssertNil(EditDistance.align(intended: Array("house"), typed: Array("mouse cat")))
        XCTAssertTrue(Keyboard.isAdjacent("e", "w"))
        XCTAssertTrue(Keyboard.isAdjacent("о", "л"))
        XCTAssertFalse(Keyboard.isAdjacent("q", "p"))
    }

    // MARK: Corrections

    func testFixesCommonTypos() {
        let engine = makeEngine()
        let cases = ["teh": "the", "recieve": "receive", "becuase": "because", "adn": "and",
                     "wiht": "with", "Teh": "The", "првиет": "привет", "спасибл": "спасибо"]
        for (typed, expected) in cases {
            let s = engine.suggest(typed, before: nil, sentenceStart: true)
            XCTAssertEqual(s?.replacement, expected, typed)
            XCTAssertGreaterThanOrEqual(s?.confidence ?? 0, 0.95, typed)
        }
    }

    func testLeavesRealAndUnusualWordsAlone() {
        let engine = makeEngine()
        let threshold = 0.95
        for word in ["the", "form", "from", "привет", "github", "kubernetes", "USA", "iPhone", "didnt", "dont"] {
            let s = engine.suggest(word, before: nil, sentenceStart: false)
            let required = (s?.typedIsWord ?? false) ? 0.99 : threshold
            XCTAssertLessThan(s?.confidence ?? 0, required, "\(word) → \(s?.replacement ?? "")")
        }
        // Capitalized mid-sentence reads as a name.
        XCTAssertLessThan(engine.suggest("Adilet", before: "with", sentenceStart: false)?.confidence ?? 0, 0.95)
    }

    // MARK: Session

    func testActiveModeCorrectsAndBackspaceReverts() {
        let session = Session(engine: makeEngine())
        XCTAssertEqual(type("teh ", into: session), [Replacement(deleteCount: 4, text: "the ")])
        XCTAssertEqual(type("⌫", into: session), [Replacement(deleteCount: 3, text: "teh")])
        // The restored word is not corrected again.
        XCTAssertEqual(type(" ", into: session), [])
    }

    func testUndoRetypesEverythingAfterTheWord() {
        let session = Session(engine: makeEngine())
        _ = type("teh ca", into: session)
        XCTAssertEqual(session.undoLastCorrection(), Replacement(deleteCount: 6, text: "teh ca"))
        XCTAssertNil(session.undoLastCorrection())
    }

    func testUndoLowersConfidenceNextTime() {
        let engine = makeEngine()
        let session = Session(engine: engine)
        _ = type("teh ", into: session)
        _ = session.undoLastCorrection()
        XCTAssertLessThan(engine.suggest("teh", before: nil, sentenceStart: true)?.confidence ?? 0, 0.95)
    }

    func testNeverCorrectsOnReturn() {
        let session = Session(engine: makeEngine())
        XCTAssertEqual(type("teh\n", into: session), [])
    }

    func testShadowModeLogsButDoesNotEdit() {
        let engine = makeEngine(mode: .shadow)
        let session = Session(engine: engine)
        XCTAssertEqual(type("teh ", into: session), [])
        XCTAssertEqual(engine.model.log.last?.status, .suggested)
        // Fixing it yourself the same way confirms the suggestion.
        _ = type("⌫⌫⌫⌫the ", into: session)
        XCTAssertEqual(engine.model.log.last?.status, .selfFixed)
        XCTAssertEqual(engine.model.pairs[LearnedModel.pairKey("teh", "the")]?.fixedByYou, 1)
    }

    func testLearnsYourOwnFixes() {
        let engine = makeEngine(mode: .shadow)
        let session = Session(engine: engine)
        _ = type("hello wrold⌫⌫⌫⌫⌫world ", into: session)
        _ = type("thw⌫e ", into: session)
        XCTAssertEqual(engine.model.ops["t:or"], 1)
        XCTAssertEqual(engine.model.ops["s:ew"], 1)
        XCTAssertEqual(engine.model.totalErrors, 2)
    }

    func testKeepsOnlyHashesOfUnknownWords() {
        let engine = makeEngine()
        let session = Session(engine: engine)
        _ = type("blorvex blorvex blorvex blorvex\n", into: session)
        XCTAssertFalse(engine.model.userWords.keys.contains("blorvex"))
        XCTAssertEqual(engine.model.userWords.count, 1)
        XCTAssertNil(engine.suggest("blorvex", before: nil, sentenceStart: true))
    }

    func testModelRoundTripsThroughCodable() throws {
        let engine = makeEngine()
        _ = type("teh quick ", into: Session(engine: engine))
        let data = try JSONEncoder().encode(engine.model)
        let decoded = try JSONDecoder().decode(LearnedModel.self, from: data)
        XCTAssertEqual(decoded.log.count, engine.model.log.count)
        XCTAssertEqual(decoded.unigrams, engine.model.unigrams)
    }

    // MARK: Quality and speed

    /// Plants one random keyboard-style typo in common words and checks the fixes it makes.
    func testSyntheticTypoPrecision() {
        let engine = makeEngine()
        var generator = SeededGenerator(seed: 42)
        for lang in Lang.allCases {
            let lexicon = Self.lexicons[lang]!
            let rows = Keyboard.rows[lang]!.flatMap { $0 }
            var fixed = 0, wrong = 0, cleanTouched = 0, trials = 0
            for rank in stride(from: 0, to: 8000, by: 4) {
                let word = lexicon.words[rank]
                guard word.count >= 4 else { continue }
                trials += 1
                var chars = Array(word)
                let i = Int.random(in: 0..<(chars.count - 1), using: &generator)
                switch Int.random(in: 0..<3, using: &generator) {
                case 0: chars.swapAt(i, i + 1)
                case 1: chars.remove(at: i)
                default:
                    let near = rows.filter { Keyboard.isAdjacent($0, chars[i]) }
                    chars[i] = near.randomElement(using: &generator) ?? chars[i]
                }
                let typo = String(chars)
                if let s = engine.suggest(typo, before: nil, sentenceStart: true), s.confidence >= 0.95,
                   lexicon.id(of: typo) == nil {
                    if s.replacement == word { fixed += 1 } else { wrong += 1 }
                }
                if let s = engine.suggest(word, before: nil, sentenceStart: true), s.confidence >= 0.99 {
                    cleanTouched += 1
                }
            }
            let precision = Double(fixed) / Double(max(1, fixed + wrong))
            print("[\(lang)] typos fixed \(fixed)/\(trials), wrong fixes \(wrong), precision \(String(format: "%.3f", precision)), clean words touched \(cleanTouched)")
            XCTAssertGreaterThan(precision, 0.9)
            XCTAssertEqual(cleanTouched, 0)
        }
    }

    /// Real words missing from the 50k lists (inflections, rare forms) must never be "fixed".
    func testLeavesRealOutOfListWordsAlone() {
        let engine = makeEngine()
        let endings: [Lang: [String]] = [
            .en: ["ing", "ed", "ly", "ness", "er", "est", "s", "able", "ment", "ful"],
            .ru: ["ами", "ями", "ого", "ему", "ыми", "ими", "ешь", "ете", "ую", "ой", "ах", "ом", "ить", "ется", "ался"],
        ]
        for lang in Lang.allCases {
            let lexicon = Self.lexicons[lang]!
            var checked = 0, changed: [String] = []
            for rank in stride(from: 200, to: 20000, by: 7) where checked < 1500 {
                let word = lexicon.words[rank]
                guard word.count >= 5 else { continue }
                for cut in 0...2 {
                    for ending in endings[lang]! {
                        let form = String(word.dropLast(cut)) + ending
                        guard lexicon.id(of: form) == nil, Self.systemDictionary(form, lang) else { continue }
                        checked += 1
                        if (engine.suggest(form, before: nil, sentenceStart: true)?.confidence ?? 0) >= 0.95 {
                            changed.append(form)
                        }
                    }
                }
            }
            print("[\(lang)] real out-of-list words changed: \(changed.count)/\(checked)")
            XCTAssertEqual(changed, [])
        }
    }

    func testSpeed() {
        let engine = makeEngine()
        let words = (0..<2000).map { Self.lexicons[.en]!.words[$0 * 7] + "x" }
        let start = DispatchTime.now().uptimeNanoseconds
        for w in words { _ = engine.suggest(w, before: "the", sentenceStart: false) }
        let micros = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000 / Double(words.count)
        print("suggest(): \(String(format: "%.1f", micros)) µs per word")
        XCTAssertLessThan(micros, 2000)
    }

    func testRetypedWordLearnsPairButHalfWordDoesNot() {
        let engine = makeEngine(mode: .shadow)
        let session = Session(engine: engine)
        _ = type("wiht⌫⌫⌫⌫with reci⌫eve ", into: session)
        XCTAssertEqual(engine.model.pairs[LearnedModel.pairKey("wiht", "with")]?.fixedByYou, 1)
        XCTAssertNil(engine.model.pairs[LearnedModel.pairKey("reci", "receive")])
    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
