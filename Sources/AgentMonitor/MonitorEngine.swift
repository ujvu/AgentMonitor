import Cocoa

/// Delegate protocol for monitor-engine-level events.
protocol MonitorEngineDelegate: AnyObject {
    /// Called when a watcher detects an attention signal (continue, approval,
    /// completion indicator, working-started, or round-completed).
    func monitorEngine(_ engine: MonitorEngine,
                       didDetectSignal signal: AttentionSignal,
                       for app: AppDefinition)
    /// Called when a watcher's state changes.
    func monitorEngine(_ engine: MonitorEngine, stateDidChangeFor app: AppDefinition)
}

/// Coordinates monitoring of all watched apps.
///
/// Creates one `AppWatcher` per `AppDefinition` and relays signals and state
/// changes to its delegate. Posts `.agentMonitorStateChanged` notifications
/// on state changes so other UI components can react.
final class MonitorEngine {

    // MARK: - Notification

    static let stateChangedNotification =
        Notification.Name("agentMonitorStateChanged")

    // MARK: - Properties

    /// The watched app definitions (see `watchedApps` in AppDefinitions.swift).
    let appDefinitions: [AppDefinition]

    weak var delegate: MonitorEngineDelegate?

    /// All watchers (AX/OCR + file-status). `StatusEmitter` is the per-provider
    /// contract — both `AppWatcher` and `FileStatusWatcher` conform.
    private var watchers: [StatusEmitter] = []
    /// Subset of `watchers` actually started by `start()`. `stop()` iterates
    /// this so an accessibility-permission loss doesn't bring down a
    /// file-provider watcher that was already running fine.
    private var startedWatchers: [StatusEmitter] = []
    private(set) var isRunning = false

    // Thread-safe state and running-flag caches.
    private let stateLock = NSLock()
    private var watcherStates: [String: WatcherState] = [:]
    private var runningFlags: [String: Bool] = [:]

    // MARK: - Init

    init() {
        appDefinitions = watchedApps
        for def in appDefinitions {
            watcherStates[def.id] = .idle
            runningFlags[def.id] = false
            // Disabled apps are kept in `appDefinitions` (so the UI can show
            // them as paused) but do NOT spawn any watcher — that saves an
            // Accessibility poll loop (or a file-poll loop) per disabled app.
            guard def.enabled else {
                Logger.shared.logInfo("MonitorEngine: skipping disabled app \(def.id) (\(def.displayName))")
                continue
            }
            // Pick the provider that matches the app's statusSource. The
            // selector is data-driven so adding a new source (e.g. .http) is
            // a one-liner in the switch.
            let emitter: StatusEmitter
            switch def.statusSource {
            case .axOCR:
                emitter = AppWatcher(definition: def)
            case .fileProvider:
                emitter = FileStatusWatcher(definition: def)
            }
            // Both AppWatcher and FileStatusWatcher expose the same delegate
            // protocol; setting self as the delegate routes everything to the
            // existing AppWatcherDelegate callbacks below.
            (emitter as? AppWatcher)?.delegate = self
            (emitter as? FileStatusWatcher)?.delegate = self
            watchers.append(emitter)
        }
        let enabledCount = appDefinitions.filter { $0.enabled }.count
        let disabledCount = appDefinitions.count - enabledCount
        Logger.shared.logInfo("MonitorEngine: registered \(enabledCount) enabled watcher(s), \(disabledCount) disabled")
    }

    // MARK: - Start / Stop

    func start() {
        guard !isRunning else { return }

        // We may have a mix of provider types. Start ONLY the ones whose
        // dependencies are available; for AX/OCR watchers this means the user
        // has granted Accessibility permission; for `.fileProvider` watchers
        // no permission is required and they always run.
        let axGranted = PermissionManager.shared.checkAccessibility()
        let watchersToStart: [StatusEmitter] = watchers.compactMap { w in
            // File-provider apps carry their declared source on the AppDefinition
            // so we can read it without a concrete type switch.
            guard let app: AppDefinition = (w as? AppWatcher)?.definition
                    ?? (w as? FileStatusWatcher)?.definition else { return nil }
            if app.statusSource.usesAccessibility && !axGranted {
                Logger.shared.logWarning(
                    "MonitorEngine: not starting [\(app.id)] — Accessibility permission not granted"
                )
                return nil
            }
            return w
        }
        if watchers.contains(where: { ($0 as? AppWatcher)?.definition.statusSource == .axOCR })
            && !axGranted {
            Logger.shared.logWarning("MonitorEngine: AX/OCR watchers idle — grant Accessibility to enable")
        }
        for w in watchersToStart { w.start() }
        startedWatchers = watchersToStart
        isRunning = !watchersToStart.isEmpty
        Logger.shared.logInfo(
            "MonitorEngine: started \(watchersToStart.count) watcher(s) of \(watchers.count) total"
        )
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        // Stop ONLY the watchers start() actually started. An
        // accessibility-permission loss should not drop file-provider
        // watchers — those don't need AX.
        for w in startedWatchers { w.stop() }
        startedWatchers = []
        Logger.shared.logInfo("MonitorEngine stopped (\(startedWatchers.count) before reset)")
    }

    /// Stops ONLY watchers whose `statusSource.usesAccessibility == true`
    /// and resets their entry in `startedWatchers`. File-provider watchers
    /// keep running. Called from the accessibility-permission-revoked path
    /// in `AppDelegate.handleAccessibilityChanged` so a TCC revoke doesn't
    /// cascade into dropping file-status monitoring.
    func stopAccessibilitySources() {
        let toStop: [StatusEmitter] = startedWatchers.filter { w in
            guard let app: AppDefinition = (w as? AppWatcher)?.definition
                    ?? (w as? FileStatusWatcher)?.definition else { return false }
            return app.statusSource.usesAccessibility
        }
        for w in toStop { w.stop() }
        startedWatchers.removeAll { w in
            guard let app: AppDefinition = (w as? AppWatcher)?.definition
                    ?? (w as? FileStatusWatcher)?.definition else { return false }
            return app.statusSource.usesAccessibility
        }
        isRunning = !startedWatchers.isEmpty
        Logger.shared.logInfo("MonitorEngine: stopped \(toStop.count) AX watcher(s); \(startedWatchers.count) file watcher(s) still running")
    }

    // MARK: - Queries

    /// Returns true if the given app's process is currently running.
    func isAppRunning(_ app: AppDefinition) -> Bool {
        let running = AXUtilities.findApp(bundleId: app.bundleId,
                                          processName: app.processName) != nil
        stateLock.lock()
        runningFlags[app.id] = running
        stateLock.unlock()
        return running
    }

    /// Returns the current `WatcherState` for the given app.
    func stateForApp(_ app: AppDefinition) -> WatcherState {
        stateLock.lock()
        let s = watcherStates[app.id] ?? .idle
        stateLock.unlock()
        return s
    }
}

// MARK: - AppWatcherDelegate

extension MonitorEngine: AppWatcherDelegate {

    func appWatcher(_ watcher: AppWatcher, didDetectSignal signal: AttentionSignal) {
        let appId = watcher.definition.id
        Logger.shared.logInfo("MonitorEngine: signal \(signal.type.label) for [\(appId)]")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.monitorEngine(self, didDetectSignal: signal, for: watcher.definition)
        }
    }

    func appWatcher(_ watcher: AppWatcher, stateDidChangeTo state: WatcherState) {
        let appId = watcher.definition.id

        // Update thread-safe cache.
        stateLock.lock()
        let prev = watcherStates[appId] ?? .idle
        watcherStates[appId] = state
        stateLock.unlock()

        guard prev != state else { return }

        Logger.shared.logInfo("MonitorEngine: [\(appId)] state \(prev.label) → \(state.label)")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.monitorEngine(self, stateDidChangeFor: watcher.definition)
            Logger.shared.logInfo("MonitorEngine: post stateChangedNotification for [\(appId)]")
            NotificationCenter.default.post(name: MonitorEngine.stateChangedNotification,
                                           object: appId)
        }
    }
}
