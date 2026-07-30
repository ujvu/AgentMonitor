import ApplicationServices
import Foundation

/// Watches a single app by polling its Accessibility tree at intervals.
///
/// Maintains state across polls to detect transitions:
/// - Send button disabled → enabled (round ended)
/// - Timer text unchanged (working stopped)
/// - "继续" button appeared (agent paused)
///
/// Fires a delegate callback when a signal is detected.
protocol AppWatcherDelegate: AnyObject {
    func appWatcher(_ watcher: AppWatcher, didDetectSignal signal: AttentionSignal)
    func appWatcher(_ watcher: AppWatcher, stateDidChange state: WatcherState)
}

final class AppWatcher {
    let definition: AppDefinition
    weak var delegate: AppWatcherDelegate?

    private(set) var state: WatcherState = .idle
    private var lastSendEnabled: Bool?
    private var lastTimerText: String?
    private var lastSignal: AttentionSignal?
    private var lastSignalTime: Date?
    private var pollTimer: DispatchSourceTimer?
    private let pollInterval: TimeInterval = 2.0
    private let dedupInterval: TimeInterval = 10.0

    private var wasWorking = false

    /// Debug log to file for troubleshooting.
    private static let logFile = "/tmp/AgentMonitor.log"
    private static var logHandle: FileHandle?
    private var pollCount = 0

    private static func log(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(ts)] \(msg)\n"
        if Self.logHandle == nil {
            FileManager.default.createFile(atPath: Self.logFile, contents: nil)
            Self.logHandle = FileHandle(forWritingAtPath: Self.logFile)
        }
        if let h = Self.logHandle {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8) ?? Data())
        }
        print(line)
    }

    init(definition: AppDefinition) {
        self.definition = definition
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTimer == nil else { return }
        Self.log("▶ 启动监控: \(definition.displayName) (bundleId: \(definition.bundleId))")
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        pollTimer = timer
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    // MARK: - Polling

    private func poll() {
        pollCount += 1

        guard let app = AXUtilities.findApp(
            bundleId: definition.bundleId,
            processName: definition.processName
        ) else {
            // App not running — update state
            if state != .idle {
                state = .idle
                lastSendEnabled = nil
                lastTimerText = nil
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.appWatcher(self, stateDidChange: .idle)
                }
            }
            return
        }

        // Try to get focused window — log if we can't
        guard let window = AXUtilities.focusedWindow(of: app) else {
            if pollCount <= 3 {
                Self.log("⚠️ [\(definition.displayName)] poll#\(pollCount): 进程在运行但无法读取窗口（AX权限问题？）")
            }
            return
        }

        var currentState = state
        var currentLastSend = lastSendEnabled
        var currentLastTimer = lastTimerText

        let signal = SignalDetector.detect(
            app: app,
            definition: definition,
            state: &currentState,
            lastSendEnabled: &currentLastSend,
            lastTimerText: &currentLastTimer
        )

        let stateChanged = currentState != state

        // Log every 5th poll or on state change
        if pollCount % 5 == 1 || stateChanged || signal != nil {
            Self.log("[\(definition.displayName)] poll#\(pollCount): state=\(currentState) changed=\(stateChanged) signal=\(signal?.type.rawValue ?? "none")")
        }

        self.state = currentState
        self.lastSendEnabled = currentLastSend
        self.lastTimerText = currentLastTimer

        if stateChanged {
            Self.log("  → [\(definition.displayName)] 状态变化: → \(currentState)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.appWatcher(self, stateDidChange: currentState)
            }
        }

        // Detect state transitions and fire appropriate signals
        if currentState == .working && !wasWorking {
            wasWorking = true
            let startSignal = AttentionSignal(
                type: .workingStarted,
                reason: "开始执行新任务",
                elementSnippet: "工作状态开始"
            )
            lastSignal = startSignal
            lastSignalTime = Date()
            Self.log("🔔 [\(definition.displayName)] 发送信号: \(startSignal.type.rawValue) - \(startSignal.reason)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.appWatcher(self, didDetectSignal: startSignal)
            }
        } else if currentState == .working {
            wasWorking = true
        } else if currentState == .idle && wasWorking {
            wasWorking = false
            let completionSignal = AttentionSignal(
                type: .roundCompleted,
                reason: "任务已完成，可以输入新消息",
                elementSnippet: "工作状态结束"
            )
            if !(lastSignal == completionSignal &&
                 lastSignalTime != nil &&
                 Date().timeIntervalSince(lastSignalTime!) < dedupInterval) {
                lastSignal = completionSignal
                lastSignalTime = Date()
                Self.log("🔔 [\(definition.displayName)] 发送信号: \(completionSignal.type.rawValue) - \(completionSignal.reason)")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.appWatcher(self, didDetectSignal: completionSignal)
                }
            }
        }

        if let signal = signal {
            if let lastSignal = lastSignal, lastSignal == signal,
               let lastTime = lastSignalTime,
               Date().timeIntervalSince(lastTime) < dedupInterval {
                Self.log("  → [\(definition.displayName)] 信号被去重跳过: \(signal.type.rawValue)")
                return
            }

            lastSignal = signal
            lastSignalTime = Date()
            Self.log("🔔 [\(definition.displayName)] 发送信号: \(signal.type.rawValue) - \(signal.reason)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.appWatcher(self, didDetectSignal: signal)
            }
        }
    }
}
