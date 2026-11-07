import AppKit
import Carbon.HIToolbox
import Observation
import os
import TypoCore

/// Status only (permissions, tap, storage). Never keystrokes or words.
private let log = Logger(subsystem: "io.github.zhqriks.TypoLearner", category: "app")

/// App state for the menu bar and dashboard. Heavy work (loading, saving) runs on `io`.
@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case loading, ready
        case failed(String)
    }

    private(set) var phase = Phase.loading
    private(set) var snapshot = Snapshot()
    private(set) var canListen = CGPreflightListenEventAccess()
    private(set) var canType = CGPreflightPostEventAccess()
    private(set) var listening = false
    /// Shown when saving is off or something was recovered.
    private(set) var storageNote: String?
    private(set) var perf = PerfMonitor.Reading()
    /// Open windows that show live numbers; nothing is refreshed while this is 0.
    var viewers = 0 {
        didSet { if viewers > oldValue { refresh() } }
    }

    var mode: Mode { snapshot.settings.mode }
    var dataFile: URL { store.file }
    var needsPermission: Bool { !canListen || (mode == .active && !canType) }

    var menuIcon: String {
        guard phase == .ready, canListen else { return "exclamationmark.triangle" }
        switch mode {
        case .off: return "eye.slash"
        case .shadow: return "eye"
        case .active: return "text.badge.checkmark"
        }
    }

    @ObservationIgnored private var core: Core?
    @ObservationIgnored private var tap: EventTap?
    @ObservationIgnored private var hotKey: HotKey?
    @ObservationIgnored private let store = SecureStore()
    @ObservationIgnored private var canSave = true
    @ObservationIgnored private let io = DispatchQueue(label: "TypoLearner.io", qos: .utility)
    @ObservationIgnored private var monitor = PerfMonitor()
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var lastMicrosPerKey: Double?

    init() {
        hotKey = HotKey(keyCode: kVK_ANSI_Z, modifiers: controlKey | optionKey) { [weak self] in
            MainActor.assumeIsolated { self?.undo() }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.save(wait: true) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.core?.setFrontmost(app?.bundleIdentifier) }
        }
        // The spell checker is set up here, on the main thread, before the tap thread uses it.
        _ = NSSpellChecker.shared
        load()
    }

    #if DEBUG
    /// For rendering the views with sample data: no tap, hotkey, timers or disk.
    init(preview engine: Engine) {
        canSave = false
        core = Core(engine: engine)
        phase = .ready
        refresh()
    }
    #endif

    // MARK: - Lifecycle

    private func load() {
        let store = store
        io.async {
            let result: Result<(Engine, String?, Bool), Error> = Result {
                guard let dir = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
                let lexicons: [Lang: Lexicon] = [
                    .en: try Lexicon.load(lang: .en, from: dir.appendingPathComponent("en_50k.txt")),
                    .ru: try Lexicon.load(lang: .ru, from: dir.appendingPathComponent("ru_50k.txt")),
                ]
                var note: String?
                var canSave = true
                var model: LearnedModel?
                do {
                    model = try store.load()
                } catch let error as SecureStore.StoreError {
                    note = error.localizedDescription
                    if case .keychain = error { canSave = false }
                }
                let engine = Engine(model: model ?? LearnedModel(), lexicons: lexicons)
                engine.isRealWord = { word, lang in
                    NSSpellChecker.shared.checkSpelling(
                        of: word, startingAt: 0, language: lang.rawValue, wrap: false,
                        inSpellDocumentWithTag: 0, wordCount: nil
                    ).location == NSNotFound
                }
                // The spell server is slow on its first call; pay that here, not mid-typing.
                _ = engine.isRealWord?("warmup", .en)
                _ = engine.isRealWord?("привет", .ru)
                // First run: save right away so the key and file exist.
                if model == nil { engine.dirty = true }
                return (engine, note, canSave)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishLoading(result) }
            }
        }
    }

    private func finishLoading(_ result: Result<(Engine, String?, Bool), Error>) {
        switch result {
        case let .success((engine, note, canSave)):
            let core = Core(engine: engine)
            core.setFrontmost(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            self.core = core
            storageNote = note
            self.canSave = canSave
            phase = .ready
            startListeningIfAllowed()
            save()
            refresh()
        case let .failure(error):
            phase = .failed("Could not start: \(error.localizedDescription)")
        }
    }

    private func tick() {
        let (listen, post) = (CGPreflightListenEventAccess(), CGPreflightPostEventAccess())
        if (listen, post) != (canListen, canType) || ticks == 0 {
            log.notice("permissions: input monitoring=\(listen), accessibility=\(post)")
        }
        canListen = listen
        canType = post
        startListeningIfAllowed()
        listening = tap?.isRunning ?? false
        ticks += 1
        if ticks % 30 == 0 { save() } // every minute
        if viewers > 0 { refresh() }
    }

    private func startListeningIfAllowed() {
        guard tap == nil, canListen, let core else { return }
        let tap = EventTap { core.handle($0, $1) }
        if tap.start() {
            self.tap = tap
            log.notice("event tap started")
        } else {
            log.error("event tap could not be created")
        }
        listening = tap.isRunning
    }

    private func refresh() {
        guard let core else { return }
        snapshot = core.snapshot()
        let timing = core.takeTiming()
        var reading = monitor.read(timing: timing)
        if reading.microsPerKey == nil { reading.microsPerKey = lastMicrosPerKey }
        lastMicrosPerKey = reading.microsPerKey
        perf = reading
    }

    private func save(wait: Bool = false) {
        guard canSave, let model = core?.takeModelIfDirty() else { return }
        let store = store
        let work: @Sendable () -> Void = {
            do {
                try store.save(model)
            } catch {
                let message = "Saving failed: \(error.localizedDescription)"
                DispatchQueue.main.async { MainActor.assumeIsolated { self.storageNote = message } }
            }
        }
        if wait { io.sync(execute: work) } else { io.async(execute: work) }
    }

    // MARK: - Actions

    func setMode(_ mode: Mode) {
        core?.updateSettings { $0.mode = mode }
        refresh()
    }

    func setThreshold(_ threshold: Double) {
        guard threshold != snapshot.settings.threshold else { return }
        core?.updateSettings { $0.threshold = threshold }
        refresh()
    }

    func block(_ bundleID: String) {
        core?.updateSettings { if !$0.blockedApps.contains(bundleID) { $0.blockedApps.append(bundleID) } }
        refresh()
    }

    func unblock(_ bundleID: String) {
        core?.updateSettings { $0.blockedApps.removeAll { $0 == bundleID } }
        refresh()
    }

    func mark(_ id: UUID, right: Bool) {
        core?.with { $0.mark(id, right: right) }
        refresh()
    }

    func unmark(_ id: UUID) {
        core?.with { $0.unmark(id) }
        refresh()
    }

    func protect(_ word: String) {
        core?.with { $0.protect(word) }
        refresh()
    }

    func clearLog() {
        core?.with { $0.clearLog() }
        save()
        refresh()
    }

    func eraseLearning() {
        core?.with { $0.eraseLearning() }
        save()
        refresh()
    }

    func undo() {
        core?.undo()
        refresh()
    }

    func requestPermissions() {
        if !canListen { CGRequestListenEventAccess() }
        if !canType { CGRequestPostEventAccess() }
    }

    func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func revealDataFile() {
        NSWorkspace.shared.activateFileViewerSelecting([store.file])
    }
}
