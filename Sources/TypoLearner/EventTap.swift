import Carbon.HIToolbox
import CoreGraphics
import Foundation
import TypoCore

/// Listen-only keyboard and mouse tap on its own thread. Listen-only means it can never block,
/// delay or alter your keystrokes; it only gets a copy.
final class EventTap {
    private var port: CFMachPort?
    private let handler: (CGEventType, CGEvent) -> Void

    init(handler: @escaping (CGEventType, CGEvent) -> Void) {
        self.handler = handler
    }

    var isRunning: Bool { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Fails until Input Monitoring is granted.
    func start() -> Bool {
        guard port == nil else { return true }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.port = port
        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "TypoLearner.EventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    fileprivate func received(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        handler(type, event)
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue().received(type, event)
    }
    return Unmanaged.passUnretained(event)
}

/// Turns raw events into what the session understands. Returns nil for events to ignore.
enum KeyMapper {
    static func map(_ type: CGEventType, _ event: CGEvent) -> KeyEvent? {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return .reset
        case .keyDown: break
        default: return nil
        }
        // Our own typing.
        if event.getIntegerValueField(.eventSourceUserData) == KeyInjector.tag { return nil }
        // Password fields turn on secure input; forget everything around them.
        if IsSecureEventInputEnabled() { return .reset }

        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        if code == kVK_ANSI_Z, flags.contains(.maskControl), flags.contains(.maskAlternate) { return nil } // undo hotkey
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return .reset }

        switch code {
        case kVK_Delete: return .backspace
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab: return .lineBreak
        case kVK_Escape, kVK_ForwardDelete, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            return .reset
        default: break
        }

        var length = 0
        var units = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &units)
        guard length > 0, let ch = String(utf16CodeUnits: units, count: length).first,
              let scalar = ch.unicodeScalars.first else { return nil }
        if (0xF700...0xF8FF).contains(scalar.value) { return .reset } // function keys
        if ch.isLetter || ch.isNumber || "'’-_".contains(ch) { return .character(ch) }
        return .separator(ch)
    }
}
