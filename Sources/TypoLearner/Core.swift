import CoreGraphics
import Foundation
import TypoCore

/// The typing session shared by the tap thread and the UI. Every access goes through the lock;
/// typing fixes is done outside it so the UI never waits on synthetic key events.
final class Core: @unchecked Sendable {
    struct Timing {
        var keys = 0
        var nanos: UInt64 = 0
    }

    private let lock = NSLock()
    private let session: Session
    private var frontmost: String?
    private var timing = Timing()
    private static let ownBundleID = Bundle.main.bundleIdentifier

    init(engine: Engine) {
        session = Session(engine: engine)
    }

    /// Called on the tap thread for every key and click.
    func handle(_ type: CGEventType, _ event: CGEvent) {
        let start = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let settings = session.engine.model.settings
        // Off mode and blocked apps: the event is not even read.
        guard settings.mode != .off, !isBlocked(settings), let key = KeyMapper.map(type, event) else {
            lock.unlock()
            return
        }
        let replacement = session.handle(key)
        timing.keys += 1
        timing.nanos += DispatchTime.now().uptimeNanoseconds - start
        lock.unlock()
        if let replacement { KeyInjector.apply(replacement) }
    }

    func setFrontmost(_ bundleID: String?) {
        with { _ in
            frontmost = bundleID
            session.reset()
        }
    }

    func undo() {
        lock.lock()
        let replacement = session.undoLastCorrection()
        lock.unlock()
        if let replacement { KeyInjector.apply(replacement) }
    }

    @discardableResult
    func with<T>(_ body: (Engine) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(session.engine)
    }

    /// Settings changes also drop the words in flight, so nothing typed before carries over.
    func updateSettings(_ change: (inout Settings) -> Void) {
        with { engine in
            change(&engine.model.settings)
            engine.dirty = true
            session.reset()
        }
    }

    func snapshot() -> Snapshot { with { $0.snapshot() } }

    /// A copy of the model to save, if it changed since the last call.
    func takeModelIfDirty() -> LearnedModel? {
        with { engine in
            guard engine.dirty else { return nil }
            engine.dirty = false
            return engine.model
        }
    }

    func takeTiming() -> Timing {
        with { _ in
            defer { timing = Timing() }
            return timing
        }
    }

    private func isBlocked(_ settings: Settings) -> Bool {
        guard let frontmost else { return false }
        return frontmost == Self.ownBundleID || settings.blockedApps.contains(frontmost)
    }
}
