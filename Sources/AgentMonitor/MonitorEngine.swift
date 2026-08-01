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

    private var watchers: [AppWatcher] = []
    private(set) var isRunning = false

    // Thread-safe state and running-flag caches.
    private let stateLock = NSLock()
    private var watcherStates: [String: WatcherState] = [:]
    private var runningFlags: [String: Bool] = [:]

    // MARK: - Init

    init() {
        appDefinitions = watchedApps
        for def in appDefinitions {
            let w = AppWatcher(definition: def)
            w.delegate = self
            watchers.append(w)
            watcherStates[def.id] = .idle
            runningFlags[def.id] = false
        }
    }

    // MARK: - Start / Stop

    func start() {
        guard !isRunning else { return }

        // Permission check: if no AX permission, don't start watchers.
        if !PermissionManager.shared.checkAccessibility() {
            Logger.shared.logError("MonitorEngine: cannot start — Accessibility permission not granted")
            return
        }

        isRunning = true
        for w in watchers { w.start() }
        Logger.shared.logInfo("MonitorEngine started (\(watchers.count) watchers)")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for w in watchers { w.stop() }
        Logger.shared.logInfo("MonitorEngine stopped")
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
