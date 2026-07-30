import Cocoa

/// Manages the app lifecycle and the status bar (menu bar) item.
///
/// The status bar icon reflects the current monitoring state:
/// • idle (monitoring, no attention needed) — blue/white dot
/// • alert (one or more agents need attention) — pulsing red dot
/// • paused (monitoring stopped) — gray dot
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Status Bar

    private var statusItem: NSStatusItem!
    private let monitorEngine = MonitorEngine()
    private var floatingPanel: FloatingNotificationPanel!
    private var statusPanel: StatusPanel!
    private var statusPanelVisible = false
    private var refreshTimer: Timer?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        setupFloatingPanel()
        setupStatusPanel()
        monitorEngine.delegate = self
        monitorEngine.start()
        print("✅ AgentMonitor 已启动，正在监控智能体窗口")

        // Show status panel by default
        showStatusPanel()

        // Periodically refresh the status panel (even when no state change)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusPanel()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        monitorEngine.stop()
    }

    // MARK: - Setup

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "eye.circle",
                accessibilityDescription: "AgentMonitor — 监控中"
            )
            button.image?.isTemplate = true
        }
        rebuildMenu()
    }

    private func setupFloatingPanel() {
        floatingPanel = FloatingNotificationPanel()
    }

    private func setupStatusPanel() {
        statusPanel = StatusPanel(apps: monitorEngine.appDefinitions)
    }

    private func showStatusPanel() {
        statusPanel.positionTopCenter()
        statusPanel.orderFrontRegardless()
        statusPanel.alphaValue = 0.0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            statusPanel.animator().alphaValue = 1.0
        })
        statusPanelVisible = true
    }

    private func hideStatusPanel() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            self.statusPanel.animator().alphaValue = 0.0
        }, completionHandler: {
            self.statusPanel.orderOut(nil)
        })
        statusPanelVisible = false
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // Title
        let titleItem = NSMenuItem()
        titleItem.title = "智能体监控"
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())

        // Toggle status panel
        let panelItem = NSMenuItem(
            title: statusPanelVisible ? "🙈 隐藏状态面板" : "👁 显示状态面板",
            action: #selector(toggleStatusPanel),
            keyEquivalent: ""
        )
        panelItem.target = self
        menu.addItem(panelItem)

        // Toggle monitoring
        let toggleItem = NSMenuItem(
            title: monitorEngine.isRunning ? "⏸ 暂停监控" : "▶ 开始监控",
            action: #selector(toggleMonitoring),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        // Per-app status
        for def in monitorEngine.appDefinitions {
            let item = NSMenuItem()
            let running = monitorEngine.isAppRunning(def)
            let state = monitorEngine.stateForApp(def)
            let symbol = running ? (state == .needsAttention ? "🔴" : (state == .working ? "🟢" : "⚪")) : "⚫"
            let stateLabel: String
            if !running {
                stateLabel = "未运行"
            } else {
                switch state {
                case .idle: stateLabel = "就绪"
                case .working: stateLabel = "工作中"
                case .needsAttention: stateLabel = "等待接手"
                }
            }
            item.title = "\(symbol) \(def.displayName) — \(stateLabel)"
            item.isEnabled = false
            menu.addItem(item)

            if state == .needsAttention {
                let jumpItem = NSMenuItem(
                    title: "  ↳ 跳转到 \(def.displayName)",
                    action: #selector(jumpToApp(_:)),
                    keyEquivalent: ""
                )
                jumpItem.target = self
                jumpItem.representedObject = def.id
                menu.addItem(jumpItem)
            }
        }

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleStatusPanel() {
        if statusPanelVisible {
            hideStatusPanel()
        } else {
            showStatusPanel()
        }
        rebuildMenu()
    }

    @objc private func toggleMonitoring() {
        if monitorEngine.isRunning {
            monitorEngine.stop()
        } else {
            monitorEngine.start()
        }
        rebuildMenu()
    }

    @objc private func jumpToApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let def = monitorEngine.appDefinitions.first(where: { $0.id == id }) else { return }
        AppActivator.activate(bundleId: def.bundleId)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Status Panel Update

    private func updateStatusPanel() {
        for def in monitorEngine.appDefinitions {
            let running = monitorEngine.isAppRunning(def)
            let state = monitorEngine.stateForApp(def)
            statusPanel.updateState(for: def, state: state, isRunning: running)
        }
    }
}

// MARK: - MonitorEngineDelegate

extension AppDelegate: MonitorEngineDelegate {

    func monitorEngine(_ engine: MonitorEngine, didDetectSignal signal: AttentionSignal, for app: AppDefinition) {
        DispatchQueue.main.async { [self] in
            // Capture screenshot of the app's window
            let screenshot = ScreenshotCapture.captureWindow(bundleId: app.bundleId)

            // Show floating notification
            floatingPanel.showNotification(
                appName: app.displayName,
                appBundleId: app.bundleId,
                reason: signal.reason,
                screenshot: screenshot
            )

            rebuildMenu()
            updateStatusPanel()
        }
    }

    func monitorEngine(_ engine: MonitorEngine, stateDidChangeFor app: AppDefinition) {
        DispatchQueue.main.async { [self] in
            rebuildMenu()
            updateStatusPanel()
        }
    }
}
