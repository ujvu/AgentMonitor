import Foundation

/// Common interface for any per-app status provider (AX/OCR watcher, file-status
/// watcher, future AppleScript / API providers, ...).
///
/// `MonitorEngine` owns a heterogeneous list of these and calls `start()` /
/// `stop()` on each, which lets the engine swap providers without changing its
/// own loop. Only the provider talks to its underlying source.
protocol StatusEmitter: AnyObject {
    var definition: AppDefinition { get }
    func start()
    func stop()
}

/// Polls an external status file written by the agent itself (a CLI, daemon,
/// or a hook inside the agent's process) and translates the JSON content
/// directly into an `AgentStatus`. Used for agents that have no detectable
/// macOS window — typical: a Web GUI served on a local port, where the AX tree
/// only sees the host browser, not the inner tab.
///
/// ### Wire protocol (v1)
///
/// ```json
/// {
///   "version": 1,
///   "agent": "deepseek-harness",
///   "status": "working",        // or idle|working|needs_input|attention|completed|error
///   "task": { "startedAt": ..., "updatedAt": ... },
///   "details": "..."
/// }
/// ```
///
/// The schema lives alongside AgentMonitor in
/// `docs/deployment-storage/dsh/` (also published as
/// `项目/智能体监控/dsh/` in the local skill repo). Stable `version` lets the
/// watcher reject incompatible payloads cleanly.
///
/// ### Staleness behavior
///
/// If `updatedAt` is older than `StatusSource.fileProviderStaleAfter`
/// (60 seconds default), the watcher reverts to `.idle` — the same lease
/// semantic as OCR's `hintTTL`. A dead producer can't pin a "working" state
/// forever.
///
/// ### Lifecycle
///
/// - `start()` schedules a 2s repeating poll on a private serial queue; no
///   Accessibility permission is required (file I/O only).
/// - `stop()` cancels the timer and drops any pending write, so a later
///   start() inherits no stale verdict.
/// - Producer writes the file with atomic-replace (`dsh-status-writer.sh`
///   uses `os.replace`); readers can poll at any cadence without a half-written
///   file ever appearing.
final class FileStatusWatcher: StatusEmitter {

    let definition: AppDefinition
    /// Absolute path to the JSON file this watcher polls. Resolved at init
    /// from `definition.statusSource` and validated to be non-empty.
    let path: String

    weak var delegate: AppWatcherDelegate?

    private let pollInterval: TimeInterval
    private let staleAfter: TimeInterval

    // MARK: - Lifecycle

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "cn.qwenwork.AgentMonitor.FileStatusWatcher",
                                      qos: .utility)
    private let decoder = JSONDecoder()

    init(definition: AppDefinition) {
        self.definition = definition
        guard case .fileProvider(let p) = definition.statusSource else {
            preconditionFailure("FileStatusWatcher requires .fileProvider statusSource")
        }
        self.path = p
        self.pollInterval = StatusSource.fileProviderPollInterval
        self.staleAfter = StatusSource.fileProviderStaleAfter
    }

    // MARK: - Public API

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
        Logger.shared.logInfo("FileStatusWatcher[\(definition.id)] started (file=\(path), poll=\(pollInterval)s)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        Logger.shared.logInfo("FileStatusWatcher[\(definition.id)] stopped")
    }

    // MARK: - Poll loop

    /// Reads the file, decodes it, and emits a state change. Errors are
    /// swallowed at log level — a missing or malformed file does not flip
    /// the visible state (the previous verdict survives until a producer
    /// writes something readable).
    private func poll() {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let payload = try decoder.decode(Payload.self, from: data)
            let snapshot = makeSnapshot(from: payload)
            emit(snapshot)
        } catch {
            // Two expected recurring cases at runtime:
            //   - file does not exist yet (producer hasn't started)
            //   - producer wrote partial JSON just before this poll
            // Both are logged at debug only — we never log them as errors
            // because they don't indicate a real problem.
            Logger.shared.logDebug(
                "FileStatusWatcher[\(definition.id)]: poll skipped — \(Self.shortError(error))"
            )
        }
    }

    private func emit(_ snapshot: StateSnapshot) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.appWatcher(self.asAppWatcherShim, stateDidChangeTo: snapshot)
        }
    }

    /// `delegate` is typed `AppWatcherDelegate` so the existing
    /// `MonitorEngine: AppWatcherDelegate` callback path can be reused.
    /// We don't actually need an `AppWatcher` instance — this shim is only
    /// the type-level handle that satisfies the protocol. Build a stub once.
    private lazy var asAppWatcherShim: AppWatcher = AppWatcher(definition: definition)

    // MARK: - JSON schema

    /// JSON wire format v1. Optional fields stay optional so a minimal
    /// producer (heartbeat-only) still works.
    private struct Payload: Decodable {
        let version: Int?
        let agent: String?
        let status: String
        let task: TaskInfo?
        let details: String?

        struct TaskInfo: Decodable {
            let startedAt: TimeInterval?
            let updatedAt: TimeInterval?
        }
    }

    // MARK: - Translation

    private func makeSnapshot(from p: Payload) -> StateSnapshot {
        // Wire format strings are forgiving: we accept the AgentStatus raw
        // values plus aliases introduced over time (e.g. "attention" as a
        // nickname for "needsAttention"; "needs_input" matches UX expectations).
        let status: AgentStatus
        switch p.status.lowercased() {
        case "idle":                                                  status = .idle
        case "working", "thinking", "running":                        status = .working
        case "needsinput", "needs_input", "attention", "needsconfirm": status = .needsAttention
        case "completed", "done", "finished", "success":              status = .completed
        default:
            Logger.shared.logWarning(
                "FileStatusWatcher[\(definition.id)]: unknown status '\(p.status)' — treating as idle"
            )
            status = .idle
        }

        // Staleness: if updatedAt is older than `staleAfter`, force .idle so a
        // crashed producer can't pin "working". Same lease semantics as OCR.
        let effective: AgentStatus = {
            guard let updated = p.task?.updatedAt else { return status }
            let age = Date().timeIntervalSince1970 - updated
            if age > staleAfter {
                Logger.shared.logDebug(
                    "FileStatusWatcher[\(definition.id)]: stale (age=\(Int(age))s > \(Int(staleAfter))s) — forcing idle"
                )
                return .idle
            }
            return status
        }()

        return StateSnapshot(
            status: effective,
            evidenceSource: .fileStatus,
            confidence: 1.0,
            timestamp: Date()
        )
    }

    // MARK: - Error formatting

    /// Short, single-line description for the debug log. Avoids dumping the
    /// full system error message (which can be multi-line / contain paths).
    private static func shortError(_ error: Error) -> String {
        let ns = error as NSError
        return "code=\(ns.code) domain=\(ns.domain)"
    }
}
