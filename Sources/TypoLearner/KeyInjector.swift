import Carbon.HIToolbox
import CoreGraphics
import TypoCore

/// Applies a fix by pressing Delete and typing the replacement, which works in every app.
enum KeyInjector {
    /// Marks our own events so the tap ignores them.
    static let tag: Int64 = 0x7479_706F

    static func apply(_ replacement: Replacement) {
        let source = CGEventSource(stateID: .privateState)
        for _ in 0..<replacement.deleteCount {
            post(source, key: CGKeyCode(kVK_Delete), text: nil)
        }
        for ch in replacement.text {
            let key = ch == " " ? CGKeyCode(kVK_Space) : 0
            post(source, key: key, text: Array(String(ch).utf16))
        }
    }

    private static func post(_ source: CGEventSource?, key: CGKeyCode, text: [UniChar]?) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            // Held modifiers (e.g. ⌃⌥ from the undo hotkey) must not turn these into shortcuts.
            event.flags = []
            if let text { event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text) }
            event.setIntegerValueField(.eventSourceUserData, value: tag)
            event.post(tap: .cgSessionEventTap)
        }
    }
}
