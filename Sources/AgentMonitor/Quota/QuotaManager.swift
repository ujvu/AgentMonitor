import Foundation

extension Notification.Name {
    static let quotaSnapshotsDidChange = Notification.Name("AgentMonitor.QuotaSnapshotsDidChange")
    /// 某个额度窗口从「已用尽」恢复为「可用」时发出（用户需要看到提醒）。
    static let quotaRecoveryDidOccur = Notification.Name("AgentMonitor.QuotaRecoveryDidOccur")
    /// 用量恶化（偏低→用尽 / 正常→偏低）时发出，悬浮岛主动提醒用户。
    static let quotaAlertDidOccur = Notification.Name("AgentMonitor.QuotaAlertDidOccur")
}

/// 一个额度窗口恢复可用的事件。
struct QuotaRecoveryEvent {
    let providerID: QuotaProviderID
    let providerName: String
    let windowName: String
    /// 恢复后的剩余百分比（>0）。
    let remainingPercent: Double
}

/// 用量恶化提醒事件（正常→偏低 或 偏低/正常→用尽）。
struct QuotaAlertEvent {
    let providerID: QuotaProviderID
    let providerName: String
    let state: QuotaState
    /// 单行摘要（含状态前缀 + 窗口剩余百分比），不含密钥。
    let summary: String
    /// 不含状态前缀的详情（如 "5小时 0% / 周额度 7%"），供悬浮岛显示。
    var detail: String {
        let prefix = state.label + " · "
        return summary.hasPrefix(prefix) ? String(summary.dropFirst(prefix.count)) : summary
    }
}

/// 额度中心：统一管理 Provider、Keychain、定时刷新、缓存与变更通知。
/// 与 Agent 状态检测链完全独立，不依赖 AX/OCR/Fusion/MonitorEngine。
final class QuotaManager {
    private static let accessRepairKey = "QuotaKeychainACLRepairedV1"
    private let credentialStore: QuotaCredentialStore
    private let providers: [QuotaProvider]
    private let stateQueue = DispatchQueue(label: "com.cuishiming.AgentMonitor.quota-state")
    private let timerQueue = DispatchQueue(label: "com.cuishiming.AgentMonitor.quota-timer", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var cache: [QuotaProviderID: QuotaSnapshot] = [:]
    /// Menu-facing credential state. The menu must never synchronously touch
    /// Keychain on the AppKit main thread; values are refreshed in the quota
    /// queue and default to "not configured" until the first lookup returns.
    private var credentialAvailability: [QuotaProviderID: Bool] = [:]
    /// 每个额度窗口上次是否「已用尽」（remainingPercent <= 0）。
    /// 键：`"\(providerID).\(windowName)"`。用于边缘检测：从用完→恢复时发提醒。
    private var lastWindowExhausted: [String: Bool] = [:]
    /// 每个 Provider 上次的产品状态（available/warning/exhausted）。
    /// 用于用量恶化边缘检测：正常→偏低 / 偏低·正常→用尽 时发提醒。
    /// 首次刷新不检测（避免启动时对已持续的低额度轰炸）；failed/unconfigured
    /// 等中间态不覆盖记录，下次真实状态变化仍能正确触发。
    private var lastProviderState: [QuotaProviderID: QuotaState] = [:]

    init(credentialStore: QuotaCredentialStore = QuotaKeychainStore()) {
        self.credentialStore = credentialStore
        self.providers = [
            MiniMaxQuotaProvider(credentialStore: credentialStore),
            GLMQuotaProvider(credentialStore: credentialStore),
            DeepSeekQuotaProvider(credentialStore: credentialStore)
        ]
        for id in QuotaProviderID.allCases {
            cache[id] = .loading(id)
        }
    }

    deinit {
        stop()
    }

    var snapshots: [QuotaSnapshot] {
        stateQueue.sync {
            QuotaProviderID.allCases.compactMap { cache[$0] }
        }
    }

    func snapshot(for id: QuotaProviderID) -> QuotaSnapshot {
        stateQueue.sync { cache[id] ?? .loading(id) }
    }

    func hasCredential(for id: QuotaProviderID) -> Bool {
        do {
            return try credentialStore.credential(for: id)?.isEmpty == false
        } catch {
            Logger.shared.logWarning("额度密钥状态读取失败 [\(id.rawValue)]: \(error.localizedDescription)")
            return false
        }
    }

    /// Non-blocking menu lookup. Unlike `hasCredential(for:)`, this only reads
    /// the in-memory result populated by `refreshCredentialAvailability()`.
    func cachedHasCredential(for id: QuotaProviderID) -> Bool {
        stateQueue.sync { credentialAvailability[id] ?? false }
    }

    /// 启动后立即刷新；此后按固定间隔刷新。默认 5 分钟。
    func start(refreshInterval: TimeInterval = 300) {
        stop()
        if !UserDefaults.standard.bool(forKey: Self.accessRepairKey) {
            // Legacy ACL repair may require one user approval. Keep it off the
            // AppKit thread and only start normal credential/API reads after it
            // finishes, preventing duplicate prompts during the migration.
            timerQueue.async { [weak self] in
                guard let self = self else { return }
                if self.repairLegacyKeychainAccessIfNeeded() {
                    self.refreshCredentialAvailability()
                    self.refreshAll()
                }
            }
        } else {
            refreshCredentialAvailability()
            refreshAll()
        }

        let source = DispatchSource.makeTimerSource(queue: timerQueue)
        source.schedule(deadline: .now() + refreshInterval, repeating: refreshInterval)
        source.setEventHandler { [weak self] in
            self?.refreshAll()
        }
        source.resume()
        timer = source
        Logger.shared.logInfo("QuotaManager 已启动，刷新间隔 \(Int(refreshInterval)) 秒")
    }

    func stop() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    func refreshAll() {
        providers.forEach { refresh(providerID: $0.id) }
    }

    func refresh(providerID: QuotaProviderID) {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return }
        update(.loading(providerID), notify: false)

        // Providers synchronously read Keychain before starting their HTTP
        // request. Execute that part off the main thread so a slow/locked
        // Keychain cannot freeze the status item or delay monitor startup.
        timerQueue.async { [weak self] in
            provider.fetchQuota { [weak self] result in
                guard let self = self else { return }
                switch result {
                case let .success(snapshot):
                    self.update(snapshot, notify: true)
                    Logger.shared.logInfo("额度刷新 [\(providerID.rawValue)]: \(snapshot.menuSummary)")
                case let .failure(error):
                    let snapshot = QuotaSnapshot.failed(providerID,
                        message: error.localizedDescription)
                    self.update(snapshot, notify: true)
                    Logger.shared.logWarning("额度刷新失败 [\(providerID.rawValue)]: \(error.localizedDescription)")
                }
            }
        }
    }

    func saveCredential(_ credential: String, for id: QuotaProviderID) throws {
        try credentialStore.saveCredential(credential, for: id)
        stateQueue.async { [weak self] in
            self?.credentialAvailability[id] = true
        }
        Logger.shared.logInfo("额度密钥已保存到 Keychain [\(id.rawValue)]")
        refresh(providerID: id)
    }

    func deleteCredential(for id: QuotaProviderID) throws {
        try credentialStore.deleteCredential(for: id)
        stateQueue.async { [weak self] in
            self?.credentialAvailability[id] = false
        }
        Logger.shared.logInfo("额度密钥已从 Keychain 删除 [\(id.rawValue)]")
        update(.unconfigured(id), notify: true)
    }

    /// Reads credential presence away from the AppKit main thread. A missing
    /// or locked Keychain item only delays the menu label refresh; monitoring
    /// and the floating island remain responsive.
    private func refreshCredentialAvailability() {
        let ids = QuotaProviderID.allCases
        timerQueue.async { [weak self] in
            guard let self = self else { return }
            var values: [QuotaProviderID: Bool] = [:]
            for id in ids {
                do {
                    values[id] = try self.credentialStore.credential(for: id)?.isEmpty == false
                } catch {
                    values[id] = false
                    Logger.shared.logWarning("额度密钥状态读取失败 [\(id.rawValue)]: \(error.localizedDescription)")
                }
            }
            self.stateQueue.sync {
                self.credentialAvailability.merge(values) { _, new in new }
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .quotaSnapshotsDidChange,
                    object: self)
            }
        }
    }

    /// One-time compatibility migration for credentials created before the
    /// current signed-app ACL was introduced. Existing API keys are read once,
    /// then recreated with the current app's trusted access. No key material
    /// is logged or persisted outside Keychain.
    @discardableResult
    private func repairLegacyKeychainAccessIfNeeded() -> Bool {
        guard let keychain = credentialStore as? QuotaKeychainStore else {
            UserDefaults.standard.set(true, forKey: Self.accessRepairKey)
            return true
        }

        var allHandled = true
        for id in QuotaProviderID.allCases {
            do {
                _ = try keychain.recreateCredentialWithCurrentAccess(for: id)
            } catch {
                allHandled = false
                Logger.shared.logWarning("额度密钥访问权限修复失败 [\(id.rawValue)]: \(error.localizedDescription)")
            }
        }

        if allHandled {
            UserDefaults.standard.set(true, forKey: Self.accessRepairKey)
            Logger.shared.logInfo("额度密钥访问权限已完成一次性修复")
            return true
        } else {
            Logger.shared.logWarning("额度密钥访问权限修复未完成，下次启动将继续尝试")
            return false
        }
    }

    private func update(_ snapshot: QuotaSnapshot, notify: Bool) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            self.cache[snapshot.providerID] = snapshot

            // 边缘检测：窗口从「已用尽」翻转为「可用」→ 发恢复提醒。
            // 只在存在上次状态时检测（首次刷新不报，避免启动时误报已恢复）。
            var recoveries: [QuotaRecoveryEvent] = []
            for window in snapshot.windows {
                guard let remaining = window.remainingPercent else { continue }
                let key = "\(snapshot.providerID.rawValue).\(window.name)"
                let nowExhausted = remaining <= 0
                if let wasExhausted = self.lastWindowExhausted[key] {
                    if wasExhausted && !nowExhausted {
                        recoveries.append(QuotaRecoveryEvent(
                            providerID: snapshot.providerID,
                            providerName: snapshot.providerName,
                            windowName: window.name,
                            remainingPercent: remaining))
                    }
                }
                self.lastWindowExhausted[key] = nowExhausted
            }

            // 用量恶化边缘检测：正常→偏低、偏低/正常→用尽 时发主动提醒。
            // 首次刷新（无上次状态）时若已处于偏低/用尽也提醒一次——用户
            // 打开应用就能知道当前用量告警，而不是等下一次状态变化。
            // 每次启动最多一次（lastProviderState 记录后即走边缘检测）。
            var alerts: [QuotaAlertEvent] = []
            if notify {
                let isFirst = self.lastProviderState[snapshot.providerID] == nil
                if isFirst {
                    switch snapshot.state {
                    case .warning, .exhausted:
                        alerts.append(QuotaAlertEvent(providerID: snapshot.providerID,
                                                      providerName: snapshot.providerName,
                                                      state: snapshot.state,
                                                      summary: snapshot.menuSummary))
                    default:
                        break
                    }
                } else if let lastState = self.lastProviderState[snapshot.providerID] {
                    switch snapshot.state {
                    case .exhausted where lastState == .available || lastState == .warning:
                        alerts.append(QuotaAlertEvent(providerID: snapshot.providerID,
                                                      providerName: snapshot.providerName,
                                                      state: .exhausted,
                                                      summary: snapshot.menuSummary))
                    case .warning where lastState == .available:
                        alerts.append(QuotaAlertEvent(providerID: snapshot.providerID,
                                                      providerName: snapshot.providerName,
                                                      state: .warning,
                                                      summary: snapshot.menuSummary))
                    default:
                        break
                    }
                }
            }
            // 只记录真实产品状态;loading/failed/unconfigured 不覆盖,
            // 保证下次真实状态变化仍能正确触发边缘检测。
            switch snapshot.state {
            case .available, .warning, .exhausted:
                self.lastProviderState[snapshot.providerID] = snapshot.state
            default:
                break
            }

            guard notify else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .quotaSnapshotsDidChange,
                    object: self,
                    userInfo: ["providerID": snapshot.providerID.rawValue])
                // 恢复提醒单独发通知（UI 层可决定如何展示）。
                for event in recoveries {
                    Logger.shared.logInfo("额度恢复 [\(event.providerID.rawValue)] \(event.windowName) → 剩余 \(Int(event.remainingPercent.rounded()))%")
                    NotificationCenter.default.post(
                        name: .quotaRecoveryDidOccur,
                        object: self,
                        userInfo: ["event": event])
                }
                // 用量恶化提醒（悬浮岛主动弹出）。
                for alert in alerts {
                    Logger.shared.logWarning("额度告警 [\(alert.providerID.rawValue)]: \(alert.detail)")
                    NotificationCenter.default.post(
                        name: .quotaAlertDidOccur,
                        object: self,
                        userInfo: ["event": alert])
                }
            }
        }
    }
}
