import Cocoa

/// Manages the app lifecycle and the status bar (menu bar) item.
///
/// AgentMonitor runs as a menu-bar-only (accessory) app: no Dock icon, just a
/// status bar item. The UI is a single pixel-styled **Floating Island** that
/// sits at the top-center of the screen and morphs between states:
///   • compact   — `🤖 AI` pill when idle.
///   • list      — all agents when the pointer hovers.
///   • expanded  — the featured agent on a state change (working / completed /
///                 needs-attention), with an energy bar and auto-collapse.
/// One window, one state machine — like macOS Dynamic Island.
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private let monitorEngine = MonitorEngine()
    private let quotaManager = QuotaManager()
    private var floatingIsland: FloatingIsland!
    private var refreshTimer: Timer?
    private let loginItemManager = LoginItemManager.shared

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One-shot CLI hook (enables launch-at-login from outside, since
        // SMAppService must be registered from inside the app process):
        //   open /Applications/AgentMonitor.app --args --enable-login-item
        if ProcessInfo.processInfo.arguments.contains("--enable-login-item") {
            do {
                try loginItemManager.enable()
                Logger.shared.logInfo("开机启动已开启 (CLI hook)")
            } catch {
                Logger.shared.logError("开启开机启动失败: \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
            return
        }

        // 1. Status bar
        setupStatusBar()
        // 2. Floating island — the single UI component
        setupFloatingIsland()
        // 3. Engine delegate
        monitorEngine.delegate = self

        // v9 Phase 1 verification: log StateEvent → IslandScene mapping once
        // at startup. No UI rewiring yet — this just confirms the new
        // presentation layer produces correct scenes for every AgentStatus.
        IslandPresentationEngine.demoRunSelfTest()

        // 4. Check permissions
        let axGranted = PermissionManager.shared.checkAccessibility()
        let screenGranted = PermissionManager.shared.checkScreenRecording()
        Logger.shared.logStartupDiagnostics(
            accessibilityGranted: axGranted,
            screenRecordingGranted: screenGranted
        )

        // 5. Start engine if AX granted, otherwise prompt
        // The engine itself now handles the per-source permission split: it
        // starts file-provider sources regardless of AX, and only starts AX/OCR
        // sources when permission is granted. So we always call start() and
        // request permission in parallel for AX sources.
        monitorEngine.start()
        Logger.shared.logInfo(
            "AgentMonitor: engine started (AX granted=\(axGranted), \(monitorEngine.appDefinitions.filter{$0.enabled && $0.statusSource.usesAccessibility}.count) AX watcher(s), \(monitorEngine.appDefinitions.filter{$0.enabled && !$0.statusSource.usesAccessibility}.count) file watcher(s))"
        )
        if !axGranted {
            Logger.shared.logWarning("辅助功能权限未开启，触发系统授权弹窗")
            PermissionManager.shared.requestAccessibility()
        }

        // One-shot key migration: MUST run before quotaManager.start(), because
        // start() immediately refreshes all providers → reads the Keychain →
        // would prompt for the login password if the items still carry a stale
        // ACL. Migrating first force-recreates the items with a fresh ACL that
        // trusts this app, so the subsequent reads don't prompt.
        migrateKeysFromUserDefaultsIfNeeded()

        // 额度中心独立于状态检测链：启动后立即刷新，之后每 5 分钟刷新。
        quotaManager.start()

        // 6. Show the floating island (only UI component)
        showFloatingIsland()

#if DEBUG
        // DEBUG HOOK (mirrors TestMultiActive): simulate a quota-recovery event
        // once at startup to verify the alert UI without waiting for real
        // quota recovery. Enable with:
        //   defaults write com.cuishiming.AgentMonitor TestQuotaRecovery -bool true
        // Isolated under #if DEBUG: compiled out in release builds (build.sh
        // does not define DEBUG), zero runtime cost in the shipped app.
        if UserDefaults.standard.bool(forKey: "TestQuotaRecovery") {
            floatingIsland.showQuotaRecovery(
                providerName: "MiniMax",
                windowName: "5小时",
                remainingPercent: 78)
            Logger.shared.logInfo("TestQuotaRecovery: simulated quota recovery alert")
        }
#endif

        // 7. Start refresh timer (updates status icon + menu)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateUI()
            }
        }

        // 9. Listen for permission changes
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAccessibilityChanged),
            name: PermissionManager.accessibilityChangedName, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleScreenRecordingChanged),
            name: PermissionManager.screenRecordingChangedName, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleQuotaSnapshotsChanged),
            name: Notification.Name.quotaSnapshotsDidChange, object: quotaManager)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleQuotaRecovery(_:)),
            name: Notification.Name.quotaRecoveryDidOccur, object: quotaManager)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleQuotaAlert(_:)),
            name: Notification.Name.quotaAlertDidOccur, object: quotaManager)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        PermissionManager.shared.recheckAllPermissions()
        let axGranted = PermissionManager.shared.checkAccessibility()
        if axGranted && !monitorEngine.isRunning {
            monitorEngine.start()
            Logger.shared.logInfo("MonitorEngine 重启：检测到辅助功能权限已授予")
        }
        updateStatusIcon()
        rebuildMenu()
        updateUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        quotaManager.stop()
        monitorEngine.stop()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        rebuildMenu()
    }

    private func setupFloatingIsland() {
        floatingIsland = FloatingIsland(apps: monitorEngine.appDefinitions, engine: monitorEngine)
    }

    // MARK: - Status Icon

    private func updateStatusIcon() {
        let axGranted = PermissionManager.shared.checkAccessibility()
        let needsAttention = monitorEngine.appDefinitions.contains {
            monitorEngine.stateForApp($0) == .needsAttention
        }

        let symbolName: String
        var redTinted = false

        if !axGranted {
            symbolName = "eye.slash.circle"
            redTinted = true
        } else if needsAttention {
            // NOTE: the name is "eye.circle.fill", NOT "eye.fill.circle".
            // The latter does not exist in SF Symbols, so
            // `NSImage(systemSymbolName:)` returns nil — assigning nil to the
            // status button's image blanked the menu-bar icon every time any
            // agent entered needsAttention (the icon appeared to corrupt /
            // vanish until the next state change).
            symbolName = "eye.circle.fill"
        } else {
            symbolName = "eye.circle"
        }

        guard let button = statusItem.button else { return }

        // Size the glyph explicitly for the menu bar. A bare
        // `NSImage(systemSymbolName:)` comes back at its intrinsic size and
        // can render inconsistently next to the system status items.
        let sizeConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)

        var image: NSImage?
        if redTinted {
            let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: .systemRed)
            image = NSImage(systemSymbolName: symbolName,
                            accessibilityDescription: "AgentMonitor — 权限未开启")?
                .withSymbolConfiguration(sizeConfig.applying(colorConfig))
            image?.isTemplate = false
        } else {
            image = NSImage(systemSymbolName: symbolName,
                            accessibilityDescription: "AgentMonitor — 监控中")?
                .withSymbolConfiguration(sizeConfig)
            image?.isTemplate = true
        }

        // Defensive fallback: never hand the status button a nil image, or the
        // menu-bar slot goes blank/wrong. If the chosen symbol is unavailable
        // (renamed, or running on an OS that lacks it), fall back to the plain
        // eye rather than clearing the icon.
        if image == nil {
            Logger.shared.logWarning("updateStatusIcon: symbol '\(symbolName)' unavailable — falling back to eye.circle")
            image = NSImage(systemSymbolName: "eye.circle",
                            accessibilityDescription: "AgentMonitor")?
                .withSymbolConfiguration(sizeConfig)
            image?.isTemplate = true
        }
        button.image = image
    }

    // MARK: - Menu

    private func rebuildMenu() {
        // Skip while the menu is open: the island already shows real-time
        // status, and rebuilding mid-interaction would yank a submenu the user
        // is reading shut. The next open rebuilds from current state.
        guard !(statusItem.button?.isHighlighted ?? false) else { return }

        let menu = NSMenu()

        // Title
        let titleItem = NSMenuItem()
        titleItem.title = "AgentMonitor"
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())

        // 智能体 (submenu): on-demand read-only status of each monitored agent,
        // plus a jump-to affordance when one needs attention. The floating
        // island owns real-time feedback; this is the manual "check status" view.
        let agentSub = NSMenu()
        for def in monitorEngine.appDefinitions {
            let running = monitorEngine.isAppRunning(def)
            let state = monitorEngine.stateForApp(def)

            // Disabled apps are kept in appDefinitions (so they round-trip the
            // "enabled" switch) but the menu must mark them as paused instead of
            // showing live state — otherwise the user sees a stale "工作中"
            // /"未运行" line for an agent whose watcher is intentionally off.
            let symbol: String
            let stateLabel: String
            if !def.enabled {
                symbol = "🚫"
                stateLabel = "已停用"
            } else if !running {
                symbol = "⚫"
                stateLabel = "未运行"
            } else {
                switch state.status {
                case .idle:           symbol = "🔵"; stateLabel = "就绪"
                case .working:        symbol = "🟡"; stateLabel = "工作中"
                case .needsAttention: symbol = "🔴"; stateLabel = "等待接手"
                case .completed:      symbol = "🟢"; stateLabel = "已完成"
                }
            }

            let item = NSMenuItem()
            item.title = "\(symbol) \(def.displayName) — \(stateLabel)"
            item.isEnabled = false
            agentSub.addItem(item)

            if def.enabled && state == .needsAttention && running {
                let jumpItem = NSMenuItem(
                    title: "  ↳ 跳转到 \(def.displayName)",
                    action: #selector(jumpToApp(_:)),
                    keyEquivalent: "")
                jumpItem.target = self
                jumpItem.representedObject = def.id
                agentSub.addItem(jumpItem)
            }
        }
        let agentItem = NSMenuItem()
        agentItem.title = "智能体"
        agentItem.submenu = agentSub
        menu.addItem(agentItem)

        // AI 额度中心：独立展示订阅窗口和 API 余额，不参与 Agent 状态判断。
        let quotaSub = NSMenu()
        for snapshot in quotaManager.snapshots {
            let summaryItem = NSMenuItem()
            summaryItem.title = "\(snapshot.providerName) — \(snapshot.menuSummary)"
            summaryItem.isEnabled = false
            quotaSub.addItem(summaryItem)

            for window in snapshot.windows {
                var details: [String] = []
                if let remaining = window.remainingPercent {
                    details.append("剩余 \(Int(remaining.rounded()))%")
                }
                if let resetAt = window.resetAt {
                    details.append("恢复 \(formatQuotaReset(resetAt))")
                }
                if !details.isEmpty {
                    let windowItem = NSMenuItem()
                    windowItem.title = "  \(window.name)：\(details.joined(separator: " · "))"
                    windowItem.isEnabled = false
                    quotaSub.addItem(windowItem)
                }
            }

            if let balance = snapshot.balance {
                let amount = NSDecimalNumber(decimal: balance.total).stringValue
                let symbol = balance.currency.uppercased() == "CNY" ? "¥" : "\(balance.currency) "
                let balanceItem = NSMenuItem()
                balanceItem.title = "  账户余额：\(symbol)\(amount)"
                balanceItem.isEnabled = false
                quotaSub.addItem(balanceItem)
            }

            // 所有供应商（含 GLM）都支持额度/配额查询，均可配置 API Key。
            let hasCredential = quotaManager.cachedHasCredential(for: snapshot.providerID)
            let configureItem = NSMenuItem(
                title: hasCredential
                    ? "  更新 \(snapshot.providerName) API Key…"
                    : "  配置 \(snapshot.providerName) API Key…",
                action: #selector(configureQuotaCredential(_:)),
                keyEquivalent: "")
            configureItem.target = self
            configureItem.representedObject = snapshot.providerID.rawValue
            quotaSub.addItem(configureItem)

            if hasCredential {
                let deleteItem = NSMenuItem(
                    title: "  删除 \(snapshot.providerName) API Key",
                    action: #selector(deleteQuotaCredential(_:)),
                    keyEquivalent: "")
                deleteItem.target = self
                deleteItem.representedObject = snapshot.providerID.rawValue
                quotaSub.addItem(deleteItem)
            }
            quotaSub.addItem(.separator())
        }

        let refreshQuotaItem = NSMenuItem(
            title: "刷新额度", action: #selector(refreshQuota), keyEquivalent: "")
        refreshQuotaItem.target = self
        quotaSub.addItem(refreshQuotaItem)

        let quotaItem = NSMenuItem()
        quotaItem.title = "AI 额度中心"
        quotaItem.submenu = quotaSub
        menu.addItem(quotaItem)

        // Toggle floating island
        let islandItem = NSMenuItem(
            title: "👁 显示/隐藏浮岛",
            action: #selector(toggleIsland),
            keyEquivalent: "")
        islandItem.target = self
        menu.addItem(islandItem)

        // Toggle monitoring
        let toggleItem = NSMenuItem(
            title: monitorEngine.isRunning ? "⏸ 暂停监控" : "▶ 开始监控",
            action: #selector(toggleMonitoring),
            keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        // 设置 (submenu): configuration management.
        let settingsSub = NSMenu()

        // Completion sound is an app-level preference, not a macOS system
        // notification. Keep it in the user-facing settings submenu so it
        // can be changed without using defaults or restarting the app.
        let completionSoundItem = NSMenuItem(
            title: "任务音效（开始/完成）",
            action: #selector(toggleCompletionSound(_:)),
            keyEquivalent: "")
        completionSoundItem.target = self
        completionSoundItem.state = UserDefaults.standard.bool(forKey: "DisableCompletionSound")
            ? .off : .on
        settingsSub.addItem(completionSoundItem)

        // 权限管理 (submenu): setup steps folded out of the top level so the
        // everyday menu stays clean. Not a developer-only debug surface.
        let permSub = NSMenu()
        let checkPermItem = NSMenuItem(
            title: "检查权限", action: #selector(checkPermissions), keyEquivalent: "")
        checkPermItem.target = self
        permSub.addItem(checkPermItem)
        let openAxItem = NSMenuItem(
            title: "打开辅助功能设置",
            action: #selector(openAccessibilitySettings), keyEquivalent: "")
        openAxItem.target = self
        permSub.addItem(openAxItem)
        let openSrItem = NSMenuItem(
            title: "打开屏幕录制设置",
            action: #selector(openScreenRecordingSettings), keyEquivalent: "")
        openSrItem.target = self
        permSub.addItem(openSrItem)
        let permItem = NSMenuItem()
        permItem.title = "权限管理"
        permItem.submenu = permSub
        settingsSub.addItem(permItem)

        // 登录时启动 (preference)
        let loginItem = NSMenuItem(
            title: "登录时启动", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = loginItemManager.isEnabled ? .on : .off
        settingsSub.addItem(loginItem)

        let settingsItem = NSMenuItem()
        settingsItem.title = "设置"
        settingsItem.submenu = settingsSub
        menu.addItem(settingsItem)

        // 帮助 (submenu): advanced / diagnostic — kept off the top level.
        let helpSub = NSMenu()
        let logItem = NSMenuItem(
            title: "打开日志目录", action: #selector(openLogDirectory), keyEquivalent: "")
        logItem.target = self
        helpSub.addItem(logItem)
        let copyItem = NSMenuItem(
            title: "复制诊断信息", action: #selector(copyDiagnostics), keyEquivalent: "")
        copyItem.target = self
        helpSub.addItem(copyItem)
        let helpItem = NSMenuItem()
        helpItem.title = "帮助"
        helpItem.submenu = helpSub
        menu.addItem(helpItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - UI Updates

    private func showFloatingIsland() {
        floatingIsland.show()
    }

    private func hideFloatingIsland() {
        floatingIsland.hide()
    }

    /// Refreshes the floating island + control center with current states.
    private func updateUI() {
        // The floating island is event-driven (observes stateChangedNotification
        // directly) — no polling needed here. The control center has its own
        // refresh timer. This is kept for status icon / menu refresh callers.
    }

    private func formatQuotaReset(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "M月d日 HH:mm"
        }
        return formatter.string(from: date)
    }

    private func showQuotaError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "额度中心操作失败"
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    // MARK: - Actions

    @objc private func toggleIsland() {
        if floatingIsland.islandVisible { hideFloatingIsland() } else { showFloatingIsland() }
        rebuildMenu()
    }

    @objc private func refreshQuota() {
        quotaManager.refreshAll()
        rebuildMenu()
    }

    /// One-shot migration of API keys from UserDefaults → Keychain.
    /// Reads keys written externally (`defaults write ... RestoreKeyGLM/MiniMax`),
    /// saves them via the app's own `saveCredential` (which binds the ACL that
    /// trusts this app), then wipes the UserDefaults copy regardless of outcome.
    /// Logs only success/failure + key length — never the key content.
    private func migrateKeysFromUserDefaultsIfNeeded() {
        let pairs: [(key: String, id: QuotaProviderID)] = [
            ("RestoreKeyGLM", .glm),
            ("RestoreKeyMiniMax", .minimax)
        ]
        for pair in pairs {
            guard let raw = UserDefaults.standard.string(forKey: pair.key),
                  !raw.isEmpty else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Always wipe the plaintext copy first — even if save fails, we do
            // NOT want a plaintext key lingering in UserDefaults.
            UserDefaults.standard.removeObject(forKey: pair.key)
            do {
                // Force-recreate: delete first so SecItemAdd (not Update) runs,
                // binding a fresh ACL. SecItemUpdate alone would keep the old
                // (possibly broken) ACL — the root cause of repeated prompts.
                try? quotaManager.deleteCredential(for: pair.id)
                try quotaManager.saveCredential(trimmed, for: pair.id)
                Logger.shared.logInfo("Keychain restore: recreated \(pair.id.rawValue) (len=\(trimmed.count)) with fresh ACL")
            } catch {
                Logger.shared.logError("Keychain restore: FAILED for \(pair.id.rawValue) — \(error)")
            }
        }
    }

    @objc private func configureQuotaCredential(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = QuotaProviderID(rawValue: raw) else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "配置 \(id.displayName) API Key"
        alert.informativeText = "密钥只保存到 macOS Keychain，不会写入代码、日志、UserDefaults 或普通文件。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "粘贴 API Key"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try quotaManager.saveCredential(field.stringValue, for: id)
            rebuildMenu()
        } catch {
            showQuotaError(error.localizedDescription)
        }
    }

    @objc private func deleteQuotaCredential(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = QuotaProviderID(rawValue: raw) else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除 \(id.displayName) API Key？"
        alert.informativeText = "只会从 macOS Keychain 删除该密钥，不影响供应商账户。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try quotaManager.deleteCredential(for: id)
            rebuildMenu()
        } catch {
            showQuotaError(error.localizedDescription)
        }
    }

    @objc private func toggleMonitoring() {
        if monitorEngine.isRunning {
            monitorEngine.stop()
            Logger.shared.logInfo("监控已手动暂停")
        } else {
            if PermissionManager.shared.checkAccessibility() {
                monitorEngine.start()
                Logger.shared.logInfo("监控已手动启动")
            } else {
                Logger.shared.logWarning("无法启动监控：辅助功能权限未开启")
                PermissionManager.shared.requestAccessibility()
            }
        }
        updateStatusIcon()
        rebuildMenu()
    }

    @objc private func jumpToApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let def = monitorEngine.appDefinitions.first(where: { $0.id == id }) else { return }
        AppActivator.activate(bundleId: def.bundleId)
    }

    @objc private func checkPermissions() {
        PermissionManager.shared.recheckAllPermissions()
        let ax = PermissionManager.shared.checkAccessibility()
        let sr = PermissionManager.shared.checkScreenRecording()
        Logger.shared.logInfo("手动检查权限 — AX: \(ax), SR: \(sr)")
        updateStatusIcon()
        rebuildMenu()
        updateUI()
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLoginItem() {
        do {
            if loginItemManager.isEnabled {
                try loginItemManager.disable()
                Logger.shared.logInfo("已关闭开机启动")
            } else {
                try loginItemManager.enable()
                Logger.shared.logInfo("已开启开机启动")
            }
        } catch {
            Logger.shared.logError("切换开机启动失败: \(error.localizedDescription)")
        }
        rebuildMenu()
    }

    @objc private func toggleCompletionSound(_ sender: NSMenuItem) {
        let shouldDisable = !UserDefaults.standard.bool(forKey: "DisableCompletionSound")
        UserDefaults.standard.set(shouldDisable, forKey: "DisableCompletionSound")
        sender.state = shouldDisable ? .off : .on
        Logger.shared.logInfo(shouldDisable ? "已关闭完成音效" : "已开启完成音效")
        rebuildMenu()
    }

    @objc private func openLogDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let logDir = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("AgentMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logDir)
    }

    @objc private func copyDiagnostics() {
        let diagnostics = Logger.shared.copyDiagnostics()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(diagnostics, forType: .string)
        Logger.shared.logInfo("诊断信息已复制到剪贴板")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Permission Change Handlers

    @objc private func handleAccessibilityChanged() {
        let granted = PermissionManager.shared.checkAccessibility()
        if granted && !monitorEngine.isRunning {
            monitorEngine.start()
            Logger.shared.logInfo("检测到辅助功能权限已开启，启动监控")
        } else if !granted && monitorEngine.isRunning {
            // Only stop the AX-dependent sources; file-provider watchers
            // don't need Accessibility and must keep running.
            monitorEngine.stopAccessibilitySources()
            Logger.shared.logWarning("辅助功能权限被撤销，停止 AX 监控（文件源不受影响）")
        }
        updateStatusIcon()
        rebuildMenu()
        updateUI()
    }

    @objc private func handleScreenRecordingChanged() {
        PermissionManager.shared.checkScreenRecording()
        updateStatusIcon()
        rebuildMenu()
        updateUI()
    }

    /// 额度快照变化（Keychain 录入/删除或定时刷新完成）后刷新菜单，
    /// 让「AI额度中心」子菜单及时反映各 Provider 的最新状态。
    @objc private func handleQuotaSnapshotsChanged() {
        rebuildMenu()
        updateUI()
    }

    /// 额度窗口从「已用尽」恢复为「可用」→ 在 FloatingIsland 上显示持久提醒
    /// （直到用户点击才关闭）。
    @objc private func handleQuotaRecovery(_ note: Notification) {
        guard let event = note.userInfo?["event"] as? QuotaRecoveryEvent else { return }
        Logger.shared.logInfo("额度恢复提醒: \(event.providerName) \(event.windowName) 剩余 \(Int(event.remainingPercent.rounded()))%")
        floatingIsland.showQuotaRecovery(
            providerName: event.providerName,
            windowName: event.windowName,
            remainingPercent: event.remainingPercent)
    }

    /// 用量恶化（正常→偏低 / 偏低·正常→用尽）→ 在 FloatingIsland 上显示
    /// 持久提醒（直到用户点击才关闭）。
    @objc private func handleQuotaAlert(_ note: Notification) {
        guard let event = note.userInfo?["event"] as? QuotaAlertEvent else { return }
        Logger.shared.logInfo("额度告警提醒: \(event.providerName) \(event.state.label) · \(event.summary)")
        floatingIsland.showQuotaAlert(providerName: event.providerName,
                                      subtitle: event.state.label,
                                      detail: event.detail)
    }
}

// MARK: - MonitorEngineDelegate

extension AppDelegate: MonitorEngineDelegate {

    func monitorEngine(_ engine: MonitorEngine,
                       didDetectSignal signal: AttentionSignal,
                       for app: AppDefinition) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Drive the single floating island (event-driven, no system
            // notification, no separate control-center window).
            self.floatingIsland.handleSignal(signal, for: app)
            self.updateStatusIcon()
            self.rebuildMenu()
            self.updateUI()
        }
    }

    func monitorEngine(_ engine: MonitorEngine, stateDidChangeFor app: AppDefinition) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateStatusIcon()
            self.rebuildMenu()
            self.updateUI()
        }
    }
}
