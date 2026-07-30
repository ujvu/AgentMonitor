import Cocoa
import Foundation

/// Coordinates monitoring of all watched apps.
///
/// Creates one AppWatcher per AppDefinition, manages their lifecycle, and
/// forwards signals to the delegate (the AppDelegate).
protocol MonitorEngineDelegate: AnyObject {
    func monitorEngine(_ engine: MonitorEngine, didDetectSignal signal: AttentionSignal, for app: AppDefinition)
    func monitorEngine(_ engine: MonitorEngine, stateDidChangeFor app: AppDefinition)
}

final class MonitorEngine {
    weak var delegate: MonitorEngineDelegate?

    private(set) var appDefinitions: [AppDefinition] = watchedApps
    private var watchers: [AppWatcher] = []
    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true

        watchers = appDefinitions.map { def in
            let watcher = AppWatcher(definition: def)
            watcher.delegate = self
            watcher.start()
            return watcher
        }

        print("🔍 开始监控 \(watchers.count) 个智能体应用")
    }

    func stop() {
        isRunning = false
        watchers.forEach { $0.stop() }
        watchers = []
    }

    // MARK: - Status Queries

    func isAppRunning(_ def: AppDefinition) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: def.bundleId).first != nil
    }

    func stateForApp(_ def: AppDefinition) -> WatcherState {
        watchers.first(where: { $0.definition.id == def.id })?.state ?? .idle
    }
}

// MARK: - AppWatcherDelegate

extension MonitorEngine: AppWatcherDelegate {
    func appWatcher(_ watcher: AppWatcher, didDetectSignal signal: AttentionSignal) {
        delegate?.monitorEngine(self, didDetectSignal: signal, for: watcher.definition)
    }

    func appWatcher(_ watcher: AppWatcher, stateDidChange state: WatcherState) {
        delegate?.monitorEngine(self, stateDidChangeFor: watcher.definition)
    }
}
