import Cocoa

// MARK: - Island Display Model

/// What the island is currently showing (legacy display-layer enum).
///
/// Renamed to `IslandDisplayMode` in v9 Phase 1 to avoid colliding with the
/// new product-level `IslandMode` in `IslandScene.swift`. This enum is
/// scheduled for removal in Phase 2 when FloatingIsland rewires to consume
/// `IslandScene` directly.
enum IslandDisplayMode {
    case hidden    // idle: a thin sliver docked at the very top, nearly invisible
    case expanded  // working/completed: featured agent card (auto)
    case attention // needsAttention: stays expanded until resolved
    case quotaAlert // quota-recovery alert: stays expanded until the user clicks it away
    /// Collapse in progress (hide() started): the window is still on screen
    /// but the collapsing morph is running. Guards hide() idempotency so
    /// repeated dismiss calls don't restart the sequence.
    case collapsing
}

/// One agent's display data for the island.
struct IslandEntry {
    let app: AppDefinition
    let snapshot: StateSnapshot
    let isRunning: Bool
}

// MARK: - Layout Constants

/// Shared layout constants so all scene-driven draw methods stay in sync.
/// Prevents overlapping text and right-edge clipping.
///
/// Layout (expanded / attention, 260-280 wide):
/// ```
/// | pad 30 avatar pad 8  TITLE (left)  ...  STATUS (right)  pad |
/// | pad                 ENERGY BAR (or NEED ACTION)            pad |
/// ```
private enum IslandLayout {
    /// Inset from the window's outer edges to text/avatar.
    static let pad: CGFloat = 16
    /// Avatar square size (top-left).
    static let avatarSize: CGFloat = 30
    /// Gap between avatar and the text column.
    static let avatarTextGap: CGFloat = 10
    /// Vertical padding of the energy bar / debug row from the bottom.
    /// Smaller value = bar sits closer to the bottom edge of the island =
    /// more breathing room from the title text above.
    static let bottomInset: CGFloat = 6
    /// Height of the energy bar / debug strip.
    static let bottomBarHeight: CGFloat = 6
}

// MARK: - Floating Island View

/// The single "AI Island" component — a top-center floating panel that
/// morphs between states driven by `StateEvent` (and by hover-to-peek
/// when idle — see `FloatingIsland`).
///
/// - **hidden**    (idle):         a thin sliver at the top, nearly invisible.
/// - **expanded**  (working/completed): featured agent's status card.
/// - **attention** (needsAttention): featured agent held expanded with a
///                                 "NEED ACTION" prompt until resolved.
final class FloatingIslandView: NSView {

    weak var delegate: FloatingIslandViewDelegate?

    var mode: IslandDisplayMode = .hidden { didSet { needsDisplay = true } }
    var entries: [IslandEntry] = [] { didSet { needsDisplay = true } }
    /// The agent to feature in expanded/attention mode (highest-priority non-idle).
    var featured: IslandEntry? { didSet { needsDisplay = true } }
    /// The actionable scene array (built by IslandPresentationEngine) that the
    /// renderer consumes. Rotation iterates this array; featured picks the head.
    var scenes: [IslandScene] = [] { didSet { needsDisplay = true } }
    /// The currently featured scene — the renderer draws from this, never
    /// re-deciding status itself.
    var currentScene: IslandScene? { didSet { needsDisplay = true } }
    /// Signal text to show (e.g. "检测到「继续」按钮").
    var signalText: String? { didSet { needsDisplay = true } }
    /// Blink toggle (0.5s timer).
    var blinkOn = true { didSet { needsDisplay = true } }
    /// Animation frame counter (for energy bar / stars).
    var animFrame = 0 { didSet { needsDisplay = true } }
    /// Whether the pointer is currently over the island.
    var isHovering = false { didSet { needsDisplay = true } }

    // MARK: Morph display properties (driven by IslandAnimationEngine, v11)

    /// 形变引擎逐帧下发的圆角半径（Dynamic Island 语义：= min(w,h)/2 的插值），
    /// 取代原先按离散 mode 切换的静态圆角，保证 frame 与圆角严格同步。
    var morphCornerRadius: CGFloat = 2 { didSet { needsDisplay = true } }
    /// 形变引擎逐帧下发的阴影不透明度（默认 0：保持贴顶无阴影决策）。
    /// 当前渲染层不消费该维度;didSet 不再触发重绘,避免每帧无谓的
    /// 整窗重绘标记(绘制只依赖 morphCornerRadius / contentAlpha)。
    var morphShadowOpacity: CGFloat = 0
    /// 形变引擎逐帧下发的背景模糊强度（预留接口，当前不渲染）。
    var morphBlurOpacity: CGFloat = 0
    /// 内容层透明度（0=内容隐藏，1=完全显示）：展开末段淡入、收起初段
    /// 淡出。只作用于内容（头像/文字/能量条），背景与边框常驻不受影响。
    var contentAlpha: CGFloat = 1 { didSet { needsDisplay = true } }

    private var trackingArea: NSTrackingArea?

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea {
            removeTrackingArea(area)
            trackingArea = nil
        }
        // `.inVisibleRect` tracks the full visible bounds; the panel host
        // (`FloatingIsland`) extends the actual hit-target beyond the visible
        // area while in hidden mode (see `expandHitRegionForHover()`).
        let area = NSTrackingArea(rect: bounds,
                                   options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        delegate?.islandViewMouseEntered(self)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        delegate?.islandViewMouseExited(self)
    }

    override func mouseDown(with event: NSEvent) {
        // 单击(或双击)即跳转到当前 featured agent 的窗口——提示窗是
        // action 表面,点击 = 去处理/查看。收起由 hover 移开自动完成
        // (mouseExited → scheduleHoverCollapse)或状态驱动(working 结束/
        // 轮换一轮退出)。quotaAlert 的点击在 didClickAppId 内单独处理。
        let target = featured ?? entries.first
        if let t = target {
            delegate?.islandView(self, didClickAppId: t.app.id)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard mode != .hidden else { return }

        // Dynamic Island 形变：圆角半径由动画引擎逐帧下发（= min(w,h)/2 的
        // 插值），不再按离散 mode 瞬时切换，保证 frame 与圆角严格同步。
        let cornerRadius = self.morphCornerRadius
        let shape = NSBezierPath(roundedRect: bounds,
                                 xRadius: cornerRadius,
                                 yRadius: cornerRadius)
        PixelTheme.bgPanel.setFill()
        shape.fill()

        // Border highlight comes from the surface mode only (a product concept,
        // not a status judgement): attention / quota-alert surfaces pulse the
        // border; everything else keeps the quiet bright border.
        let isAttention = (mode == .attention) || (mode == .quotaAlert)
        let borderColor = (isAttention && blinkOn) ? PixelTheme.cAttention : PixelTheme.borderBright
        borderColor.setStroke()
        shape.lineWidth = 2
        shape.stroke()

        switch mode {
        case .hidden:
            drawHidden()
        case .expanded, .attention, .quotaAlert, .collapsing:
            // 内容透明度由动画引擎逐帧下发：展开末段淡入、收起初段淡出。
            // 只作用于内容层——背景 fill 与 border stroke 已在上方画完，常驻。
            if contentAlpha < 1.0 {
                NSGraphicsContext.current?.cgContext.setAlpha(contentAlpha)
            }
            // Scene-driven rendering: the presentation engine decides the
            // content; we only draw it. No scene yet (cold start) → draw
            // nothing (the island is still morphing into shape).
            if let scene = currentScene {
                drawScene(scene)
            } else {
                drawHidden()
            }
        }
    }

    // MARK: - Material intensity (reserved, currently unused)
    //
    // `PixelTheme.drawGlassBackground` and `PixelTheme.drawInnerGlow` exist
    // for future material polish but are not wired into `draw()` above — the
    // current visual style intentionally stays at the cleaner baseline
    // (background fill + border + scene content). Kept here as a product-
    // layer parameter struct so a later pass can re-enable the material
    // layer without re-deriving the per-scene tint/intensity mapping.
    private struct MaterialParams {
        let glowColor: NSColor
        let intensity: CGFloat      // 0-1,drawInnerGlow 用
        let glassTint: NSColor      // glass 底色
        let glassAlpha: CGFloat     // 0-1
    }

    // MARK: Scene-driven drawing (product layer)

    /// Draws a single `IslandScene` — the ONLY content path the renderer uses
    /// once the presentation engine is wired. Layout mirrors the legacy card:
    /// avatar (top-left), title (left), subtitle/status (right), energy bar
    /// (bottom, only for working/celebration).
    private func drawScene(_ scene: IslandScene) {
        let pad = IslandLayout.pad
        let avatarSize = IslandLayout.avatarSize

        // breathing(peek 预览)待机生命感:Date-based 独立时钟(~3s 呼吸周期,
        // 不绑 animFrame):
        // 1) 外圈 innerGlow 弱呼吸(0.1~0.2 sinus)
        // 2) 内容整体 y ±1px 缓慢浮动(saveGState/translate/restoreGState)
        // 3) 内容微光与展开末段的 contentAlpha 淡入相乘叠加
        let isBreathing = scene.animation == .breathing
        if isBreathing {
            var p = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.0)
            if p < 0 { p += 3.0 }
            let breathPhase = p / 3.0
            let wave = sin(breathPhase * .pi * 2)                       // -1~1
            let glow = 0.1 + 0.1 * (0.5 + 0.5 * wave)                   // 0.1~0.2
            PixelTheme.drawInnerGlow(in: bounds, color: PixelTheme.borderBright, intensity: glow)
            let drift = CGFloat(wave) * 1.0                             // ±1px
            let breathe = 0.85 + 0.15 * (0.5 + 0.5 * wave)              // 0.85~1.0 微光
            NSGraphicsContext.current?.cgContext.saveGState()
            NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: drift)
            NSGraphicsContext.current?.cgContext.setAlpha(contentAlpha * CGFloat(breathe))
        }

        // --- Avatar (PixelAgentVisual, app-specific pixel character) ---
        let avatarY = bounds.maxY - pad - avatarSize
        let avatarRect = NSRect(x: pad, y: avatarY, width: avatarSize, height: avatarSize)
        let color: NSColor
        switch scene.mode {
        case .attention:  color = PixelTheme.cAttention
        case .celebration: color = PixelTheme.cDone
        default:
            // zcode 专属绿色;其他 agent 用默认青色。
            color = (scene.appId == "zcode") ? PixelTheme.cZCode : PixelTheme.cRunning
        }
        // Working / completed 动画交给 PixelAgentVisual —— 它有自己的 phase 时钟,
        // 不绑 animFrame;idle 带慢周期微动作(眨眼/耳动/翅抬/角呼吸)。
        if scene.animation == .working {
            let workingPhase = PixelAgentVisual.workingPhase(for: scene.appId)
            PixelAgentVisual.drawWorking(in: avatarRect, color: color,
                                         appId: scene.appId, phase: workingPhase)
        } else if scene.animation == .complete {
            let completedPhase = PixelAgentVisual.completedPhase(for: scene.appId)
            let completedFrame = PixelAgentVisual.completedFrameIndex(phase: completedPhase, frameCount: 4)
            PixelAgentVisual.drawCompleted(in: avatarRect, color: color,
                                           appId: scene.appId, frame: completedFrame)
        } else {
            let idlePhase = PixelAgentVisual.idlePhase(for: scene.appId)
            PixelAgentVisual.drawIdle(in: avatarRect, color: color,
                                      appId: scene.appId, phase: idlePhase)
        }

        // --- Layout columns: title (left) vs subtitle (right) ---
        let titleX = pad + avatarSize + IslandLayout.avatarTextGap
        let titleColumnWidth = max(80, bounds.width * 0.50)
        let statusColumnWidth = bounds.width - titleX - titleColumnWidth - pad
        let statusColumnX = bounds.width - pad - statusColumnWidth

        // --- Title (agent name) ---
        let titleRect = NSRect(x: titleX,
                               y: avatarY + avatarSize - 16,
                               width: titleColumnWidth,
                               height: 16)
        PixelTheme.drawText(truncated(scene.title, in: titleColumnWidth, font: PixelTheme.boldFont),
                            in: titleRect,
                            font: PixelTheme.boldFont, color: PixelTheme.text, alignment: .left)

        // --- Subtitle (status word, right-aligned) ---
        if let subtitle = scene.subtitle {
            let statusRect = NSRect(x: statusColumnX,
                                    y: avatarY + avatarSize - 16,
                                    width: statusColumnWidth,
                                    height: 16)
            PixelTheme.drawText(truncated(subtitle, in: statusColumnWidth, font: PixelTheme.boldFont),
                                in: statusRect,
                                font: PixelTheme.boldFont, color: color, alignment: .right)
        }

        // --- Energy bar (working / celebration only) ---
        if scene.animation == .working || scene.animation == .complete {
            let barY = IslandLayout.bottomInset
            let barH = IslandLayout.bottomBarHeight
            let barRect = NSRect(x: pad, y: barY, width: bounds.width - pad * 2, height: barH)
            drawEnergyBar(in: barRect, color: color, animation: scene.animation, frame: animFrame)
        } else if scene.mode == .attention, let reason = signalText {
            // Attention: signal/reason text in the lower half (legacy behavior).
            let signalRectY: CGFloat = IslandLayout.bottomInset + 4
            let signalRectHeight = bounds.height - signalRectY - IslandLayout.bottomInset
            let signalRect = NSRect(x: pad,
                                    y: signalRectY,
                                    width: bounds.width - pad * 2,
                                    height: max(12, signalRectHeight))
            PixelTheme.drawText(truncated(reason, in: signalRect.width, font: PixelTheme.smallFont),
                                in: signalRect,
                                font: PixelTheme.smallFont, color: color, alignment: .center)
        }

        // 结束 breathing 的内容浮动(restore translate + alpha)。
        if isBreathing {
            NSGraphicsContext.current?.cgContext.restoreGState()
        }
    }

    // MARK: Hidden (idle — a thin sliver docked at the top, no content)

    private func drawHidden() {
        // Idle state shows nothing inside the window — no robot, no "AI",
        // no agent name, no status. The thin window sliver is the only trace.
    }


    // MARK: - Text width helper

    /// Truncates `text` with an ellipsis ("…") to fit within `maxWidth`
    /// using the given font. Prevents right-edge overflow when status labels
    /// or names would otherwise overflow the column.
    private func truncated(_ text: String, in maxWidth: CGFloat, font: NSFont) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let full = text as NSString
        if full.size(withAttributes: attrs).width <= maxWidth { return text }
        // Shrink with trailing ellipsis until it fits.
        let ellipsis = "…"
        var s = text
        while !s.isEmpty {
            s.removeLast()
            let candidate = (s + ellipsis) as NSString
            if candidate.size(withAttributes: attrs).width <= maxWidth {
                return s + ellipsis
            }
        }
        return ellipsis
    }

    // MARK: - Energy bar (flowing animation)

    /// 能量条样式由产品层 `IslandAnimation` 决定(working 流动 / complete 满条 /
    /// alert 脉冲点)。渲染层只消费 scene.animation,不参与状态编排。
    private func drawEnergyBar(in rect: NSRect,
                               color: NSColor,
                               animation: IslandAnimation,
                               frame: Int) {
        PixelTheme.fillRect(rect, color: PixelTheme.bg)
        PixelTheme.drawFrame(in: rect, color: PixelTheme.border, thickness: 1)

        let blocks = 12
        let gap: CGFloat = 1
        let blockW = (rect.width - CGFloat(blocks - 1) * gap) / CGFloat(blocks)

        switch animation {
        case .working:
            // 流动光头：从左向右扫过。
            let head = frame % (blocks + 4)
            for i in 0..<blocks {
                let bx = rect.minX + 1 + CGFloat(i) * (blockW + gap)
                let dist = abs(i - head + 2)
                let lit = dist < 4
                let c = lit ? color : PixelTheme.bgCard
                PixelTheme.fillRect(NSRect(x: bx, y: rect.minY + 1, width: blockW - 1, height: rect.height - 2), color: c)
            }
        case .complete:
            // 全满：任务完成。
            for i in 0..<blocks {
                let bx = rect.minX + 1 + CGFloat(i) * (blockW + gap)
                PixelTheme.fillRect(NSRect(x: bx, y: rect.minY + 1, width: blockW - 1, height: rect.height - 2), color: color)
            }
        case .alert:
            // 单点脉冲：需要用户处理。
            let head = frame % blocks
            for i in 0..<blocks {
                let bx = rect.minX + 1 + CGFloat(i) * (blockW + gap)
                let c = (i == head) ? color : PixelTheme.bgCard
                PixelTheme.fillRect(NSRect(x: bx, y: rect.minY + 1, width: blockW - 1, height: rect.height - 2), color: c)
            }
        case .idle, .breathing:
            // 暗淡占位。
            PixelTheme.fillRect(NSRect(x: rect.minX + 1, y: rect.minY + 1, width: blockW - 1, height: rect.height - 2),
                                color: PixelTheme.textDim)
        }
    }
}

// MARK: - Delegate

protocol FloatingIslandViewDelegate: AnyObject {
    func islandViewMouseEntered(_ view: FloatingIslandView)
    func islandViewMouseExited(_ view: FloatingIslandView)
    func islandView(_ view: FloatingIslandView, didClickAppId id: String)
}

// MARK: - FloatingIsland Panel

/// The single "Pixel AI Island" — a top-center floating panel.
///
/// Purely a **IslandScene renderer**: it receives scenes from
/// `IslandPresentationEngine` (via `IslandRotationManager`) and never decides
/// content itself. **mouse hover** can also peek: when idle, hovering the top
/// sliver expands the island for ~2s so the user can see what agents are
/// running, then it auto-collapses back. Hover never overrides working /
/// attention (those stay expanded permanently until resolved).
///
/// Replaces system notifications AND the standalone control-center window.
/// Does NOT use UNUserNotificationCenter.
final class FloatingIsland: NSPanel {

    private weak var engine: MonitorEngine?
    private let apps: [AppDefinition]
    private let container: FloatingIslandView

    // Sizes (Dynamic Island proportions — wide pill, small idle footprint)
    private let hiddenSize    = NSSize(width: 100, height: 4)   // hidden dock sliver (idle)
    private let expandedSize  = NSSize(width: 260, height: 64)  // working/completed card
    private let attentionSize = NSSize(width: 280, height: 72)  // needs-attention card (taller for action affordance)

    // v11 形变引擎：负责 Dynamic Island 形变动画（frame + cornerRadius 同步）。
    private let animationEngine = IslandAnimationEngine()
    /// Product layer: state → IslandScene. FloatingIsland consumes scenes; it
    /// never re-decides status or re-authors copy.
    private let presentationEngine = IslandPresentationEngine()
    /// Scene selection + 2s rotation among active scenes. FloatingIsland only
    /// asks "what should I show now?" — it doesn't keep index/timer itself.
    private let rotationManager = IslandRotationManager()
    /// Cross-fade between two scenes without changing geometry (no re-open of
    /// the island). Used by rotation tick to swap content smoothly.
    private lazy var sceneTransition = IslandSceneTransition(
        animationEngine: animationEngine,
        containerSceneSetter: self
    )

    // State
    private var currentMode: IslandDisplayMode = .hidden
    private var autoCollapseAt: Date?
    private var animTimer: Timer?
    private var isHovering = false
    /// Whether the current `.expanded` was triggered by hover (vs. by a real
    /// working state). When true, mouseExited schedules a 2-second collapse
    /// back to hidden. When false (real working/completed state), hover does
    /// not collapse — the state machine drives that.
    private var hoverExpanded = false
    /// Timer used by hover-to-collapse. Cancelled if the user re-enters or
    /// the state machine takes over.
    private var hoverCollapseTimer: Timer?
    /// Index into `activeAgents()` for the current rotation step. Updated by
    /// `activeAgentTimer`. Reset to 0 when rotation (re)starts.
    private var activeAgentIndex = 0
    /// Independent flag tracking whether the recursive rotation chain is
    /// currently scheduling itself. Set true by `startActiveAgentRotation`,
    /// cleared by `stopActiveAgentRotation` (which also makes the next
    /// `scheduleNextRotationTick` see `false` and bail out). Kept separate
    /// from `hoverExpanded` so that stopping rotation doesn't accidentally
    /// collapse the hover-peek state.
    private var rotationActive = false
    /// True when a multi-agent rotation round has been fully shown and the
    /// island dismissed itself. While set, `applyBestScene` keeps the island
    /// hidden for `active` scenes (agents still working must not re-open it
    /// over and over). Higher-priority states (attention / celebration) and
    /// hover peek still wake it. Cleared when nothing is actionable.
    private var rotationExhausted = false
    /// True when hide() has started the collapsing morph — finishMorph will
    /// orderOut the window once the geometry shrink completes.
    private var pendingHide = false
    /// Completion is an event, not just a durable status. Keep the explicit
    /// celebration alive while the follow-up working→idle state notification
    /// arrives, otherwise that notification can immediately hide the card.
    private var completionOverrideAppId: String?
    private var completionOverrideUntil: Date?

    init(apps: [AppDefinition], engine: MonitorEngine) {
        self.apps = apps
        self.engine = engine
        let container = FloatingIslandView()
        self.container = container

        super.init(contentRect: NSRect(origin: .zero, size: NSSize(width: 100, height: 4)),
                   styleMask: [.borderless], backing: .buffered, defer: false)

        isFloatingPanel = true
        // .statusBar sits ABOVE the menu bar, so the island can be pinned to
        // the real top edge of the screen (screen.frame.maxY) and stay visible
        // instead of being pushed below the menu bar by .floating.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isOpaque = false
        backgroundColor = .clear
        // No shadow: the panel sits flush at the top edge of the screen, and a
        // shadow makes the top border look detached / floating with a visible gap.
        hasShadow = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        container.entries = apps.map {
            IslandEntry(app: $0, snapshot: .idle, isRunning: false)
        }
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        container.delegate = self
        container.frame = contentView?.bounds ?? .zero
        contentView = container

        // v11 形变引擎回调：每帧把插值态应用到窗口 + container；完成时收尾。
        animationEngine.onApply = { [weak self] state in
            self?.applyMorph(state)
        }
        animationEngine.onComplete = { [weak self] phase in
            self?.finishMorph(phase)
        }

        // Observe state changes from the engine (pure event-driven).
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleStateChanged(_:)),
            name: MonitorEngine.stateChangedNotification, object: nil)

#if DEBUG
        installTestRemoteControl()
#endif
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
#if DEBUG
        testCommandTimer?.invalidate()
#endif
    }

#if DEBUG
    // MARK: - UI-Test Remote Control (debug builds only)

    /// Lets an external test harness drive the exact same delegate paths a
    /// real mouse would (mouseEntered → peek, single-click → dismiss).
    /// Compiled out of release builds; the harness observes the island's
    /// window geometry through the AX API.
    ///
    /// Transport: a command file (`/tmp/am_testui_cmd`) polled at 50ms —
    /// file I/O is deterministic (NSDistributedNotificationCenter proved
    /// flaky under rapid posting). One command per line, executed in order.
    ///
    /// Commands:
    ///   - "peek":    same entry point as mouseEntered on the hidden sliver
    ///   - "leave":   same entry point as mouseExited
    ///   - "dismiss": same entry point as a single click on the expanded island
    ///   - "show":    same entry point as the menu “显示/隐藏浮岛” show branch
    ///   - "complete-chatgpt": simulate the real ChatGPT completion cue
    ///   - "pause"/"resume": freeze / unfreeze the live state machine so
    ///     tests are deterministic (same entry points as the menu toggle)
    private let testCommandPath = "/tmp/am_testui_cmd"
    private var testCommandTimer: Timer?
    private var suppressQuotaAlertsForTests = false

    private func installTestRemoteControl() {
        testCommandTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.drainTestCommands() }
        }
        Logger.shared.logInfo("TestUI remote control installed (debug build, file channel)")
    }

    private func drainTestCommands() {
        guard let data = try? String(contentsOfFile: testCommandPath, encoding: .utf8) else { return }
        let lines = data.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.isEmpty else { return }
        // Clear the file first so a command arriving mid-execution is not lost.
        try? "".write(toFile: testCommandPath, atomically: true, encoding: .utf8)
        for line in lines {
            guard !line.isEmpty else { continue }
            Logger.shared.logInfo("TestUI command: \(line)")
            switch line {
            case "peek":
                self.islandViewMouseEntered(self.container)
            case "leave":
                self.islandViewMouseExited(self.container)
            case "dismiss":
                self.hide(quick: true)
            case "show":
                self.show()
            case "complete-chatgpt":
                if let app = self.apps.first(where: { $0.id == "chatgpt" }) {
                    self.presentCompletion(for: app)
                }
            case "pause":
                self.suppressQuotaAlertsForTests = true
                self.engine?.stop()
                Logger.shared.logInfo("TestUI: monitoring paused")
            case "resume":
                self.suppressQuotaAlertsForTests = false
                self.engine?.start()
                Logger.shared.logInfo("TestUI: monitoring resumed")
            default:
                Logger.shared.logWarning("TestUI unknown command: \(line)")
            }
        }
    }
#endif

    // MARK: - Show / Hide

    func show() {
        // 取消任何未完成的收起流程：collapse 过程中出现新任务/状态事件,
        // show() 应能重新展开。pendingHide=false 让 hide() 的幂等守卫放行,
        // currentMode 会随展开动画被 setMode/.expanded 覆盖。
        pendingHide = false
        refreshEntries()
        refreshScenes()
        positionTopCenter()
        // show() drives its own three-step expansion sequence below. Keep the
        // logical mode aligned with the visible geometry so a click received
        // before the next state notification can still call hide().
        let previousMode = currentMode
        currentMode = .expanded
        container.mode = .expanded
        // 引擎当前态对齐窗口真实几何（hidden 视觉 100×4，圆角 2），
        // 保证首次唤醒形变从真实当前态起步，无跳变。
        animationEngine.syncCurrent(IslandMorphState.hidden)
        orderFrontRegardless()
        Logger.shared.logInfo("FloatingIsland show() windowVisible=\(self.isVisible) mode=\(previousMode)->\(currentMode)")
        // alpha 仅作为辅助淡入——展开/收起的主动画由 IslandAnimationEngine
        // 的序列驱动（先弹高度 → 展开宽度 → 内容淡入）。
        alphaValue = 0.0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 1.0
        })
        // 展开序列（dormant → awakening → morph → contentFadeIn,60fps 形变；
        // 取消机制保证展开中途来 hide() 可作废本序列）：
        // 1) awakening: 从 100×4 弹出高度到 20（顶部胶囊出现）
        // 2) awakening: 宽度展开到完整卡片（260×64，圆角同步到 min/2）
        // 3) contentFadeIn: 内容淡入（contentAlpha → 1,几何已稳）
        let peekSize = NSSize(width: hiddenSize.width, height: 20)
        let fullRadius = min(expandedSize.width, expandedSize.height) / 2
        animationEngine.morphSequence([
            IslandMorphStep(target: IslandMorphTarget(size: peekSize,
                                                      cornerRadius: min(peekSize.width, peekSize.height) / 2),
                            phase: .awakening, duration: 0.15),
            IslandMorphStep(target: IslandMorphTarget(size: expandedSize,
                                                      cornerRadius: fullRadius),
                            phase: .awakening, duration: 0.3),
            IslandMorphStep(target: IslandMorphTarget(size: expandedSize,
                                                      cornerRadius: fullRadius,
                                                      contentAlpha: 1),
                            phase: .contentFadeIn, duration: 0.15)
        ])
        startAnimTimer()
    }

    /// Collapses the island back to its dormant sliver.
    ///
    /// - Parameter quick: `true` for a snappy collapse (~0.21s, used by
    ///   single-click dismissal); `false` for the default gentler collapse
    ///   (~0.55s, used by hover / auto-collapse paths). Both keep a visible
    ///   morph animation — quick mode just shortens each step.
    func hide(quick: Bool = false) {
        // Idempotent guard: if a collapse is already in flight (pendingHide)
        // or the window is already hidden/collapsing, do nothing. Otherwise
        // repeated clicks (or re-entrancy from state-event paths) start
        // overlapping morph sequences; the new sequence captures sequenceId,
        // the old one's `finishMorph` never fires, and `orderOut` is never
        // reached — symptom: window stays visible but contents are blanked
        // by the first sequence's contentFadeOut step.
        guard !pendingHide, currentMode != .hidden, currentMode != .collapsing else { return }
        // 收起序列（contentFadeOut → collapsing → dormant）：
        // 1) contentFadeOut: 内容淡出（contentAlpha → 0,几何尚稳）
        // 2) collapsing: 几何收缩到 100×4（finishMorph 检测到此 phase 才 orderOut）
        // 3) dormant: 保持 hidden 几何（末段,无视觉变化）
        // 取消机制保证 show() 展开中途来 hide() 会作废展开序列。
        // quick 模式（点击收起）总时长 ~0.21s，仍是可见的形变动画；
        // 默认模式 ~0.55s，用于 hover / 自动收起等被动场景。
        let fadeOutDuration: TimeInterval = quick ? 0.05 : 0.15
        let collapseDuration: TimeInterval = quick ? 0.12 : 0.3
        let dormantDuration: TimeInterval = quick ? 0.04 : 0.1
        rotationManager.stopRotation()
        pendingHide = true
        currentMode = .collapsing
        let currentSize = self.frame.size
        let currentRadius = min(currentSize.width, currentSize.height) / 2
        let dormRadius = min(hiddenSize.width, hiddenSize.height) / 2
        animationEngine.morphSequence([
            IslandMorphStep(target: IslandMorphTarget(size: currentSize,
                                                      cornerRadius: currentRadius,
                                                      contentAlpha: 0),
                            phase: .contentFadeOut, duration: fadeOutDuration),
            IslandMorphStep(target: IslandMorphTarget(size: hiddenSize,
                                                      cornerRadius: dormRadius),
                            phase: .collapsing, duration: collapseDuration),
            IslandMorphStep(target: IslandMorphTarget(size: hiddenSize,
                                                      cornerRadius: dormRadius),
                            phase: .dormant, duration: dormantDuration)
        ])
    }

    var islandVisible: Bool {
        return self.alphaValue > 0.01 && self.isOnActiveSpace
    }

    // MARK: - Event Handlers (pure display layer)

    @objc private func handleStateChanged(_ note: Notification) {
        Logger.shared.logInfo("FloatingIsland received notification")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let until = self.completionOverrideUntil,
               let appId = self.completionOverrideAppId,
               Date() < until,
               (note.object as? String) == appId {
                Logger.shared.logDebug("FloatingIsland: suppressing stale state refresh during completion celebration [\(appId)]")
                return
            }
            // Scene-driven path: rebuild the actionable scene array from the
            // engine's current states, then present the best scene. All status
            // composition lives in IslandPresentationEngine; this view only
            // reflects the resulting scene.
            self.refreshEntries()
            self.refreshScenes()
            self.applyBestScene()
        }
    }

    func handleSignal(_ signal: AttentionSignal, for app: AppDefinition) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            Logger.shared.logInfo("FloatingIsland handling signal \(signal.type.label) for [\(app.id)] mode=\(self.currentMode)")
            // Agent events outrank quota reminders. A quota alert may be
            // persistent while nothing is happening, but it must not swallow
            // a task start or completion cue.
            if signal.type == .workingStarted {
                self.presentWorkingStart(for: app)
                return
            }
            if signal.type == .roundCompleted {
                self.presentCompletion(for: app)
                return
            }
            self.container.signalText = signal.reason
            self.refreshEntries()
            self.refreshScenes()
            self.applyBestScene()
        }
    }

    /// Presents the start of a newly detected work round as an explicit event
    /// cue. This is separate from the durable `.working` scene so the event
    /// remains visible even when the state notification follows it.
    private func presentWorkingStart(for app: AppDefinition) {
        let scene = IslandScene(
            mode: .active,
            title: app.displayName.uppercased(),
            subtitle: "WORKING",
            icon: "robot_working",
            animation: .working,
            priority: 20,
            appId: app.id)

        container.currentScene = scene
        container.signalText = "任务已开始"
        refreshEntries()
        if let entry = container.entries.first(where: { $0.app.id == app.id }) {
            container.featured = entry
        }
        completionOverrideAppId = nil
        completionOverrideUntil = nil
        hoverExpanded = false
        hoverCollapseTimer?.invalidate()
        hoverCollapseTimer = nil
        rotationManager.stopRotation()
        rotationExhausted = false
        autoCollapseAt = nil
        setMode(.expanded)
        playTaskSound(named: "Pop", purpose: "开始")
        Logger.shared.logInfo("FloatingIsland task-start cue [\(app.id)]")
    }

    /// Presents a completion event independently of the persisted state. The
    /// watcher may commit `idle` immediately after emitting roundCompleted;
    /// using the engine's current scene at that point would erase the only
    /// visible completion cue.
    private func presentCompletion(for app: AppDefinition) {
        let scene = IslandScene(
            mode: .celebration,
            title: app.displayName.uppercased(),
            subtitle: "DONE",
            icon: "robot_complete",
            animation: .complete,
            priority: 30,
            appId: app.id)

        completionOverrideAppId = app.id
        completionOverrideUntil = Date().addingTimeInterval(3.5)
        container.currentScene = scene
        container.signalText = "任务已完成"
        refreshEntries()
        if let entry = container.entries.first(where: { $0.app.id == app.id }) {
            container.featured = entry
        }
        hoverExpanded = false
        hoverCollapseTimer?.invalidate()
        hoverCollapseTimer = nil
        rotationManager.stopRotation()
        rotationExhausted = false
        autoCollapseAt = Date().addingTimeInterval(3.0)
        setMode(.expanded)
        playTaskSound(named: "Hero", purpose: "完成")
        Logger.shared.logInfo("FloatingIsland completion celebration [\(app.id)]")
    }

    /// Task sounds are enabled by default. Start and completion use different
    /// built-in macOS sounds so the user can distinguish them immediately.
    /// Users who want a silent island
    /// can opt out without changing the no-system-notification behavior:
    /// `defaults write com.cuishiming.AgentMonitor DisableCompletionSound -bool true`.
    private func playTaskSound(named name: String, purpose: String) {
        guard !UserDefaults.standard.bool(forKey: "DisableCompletionSound") else { return }
        if let sound = NSSound(named: NSSound.Name(name)) {
            _ = sound.play()
            Logger.shared.logInfo("FloatingIsland task sound played [\(purpose): \(name)]")
        } else {
            NSSound.beep()
            Logger.shared.logWarning("FloatingIsland task sound fallback beep [\(purpose): \(name) unavailable]")
        }
    }

    // MARK: - Quota alert

    /// Shows a persistent quota alert on the island (额度已用尽 / 额度偏低 /
    /// 额度已恢复): stays expanded until the user clicks it away (unlike
    /// attention, which resolves via the state machine). A task event may
    /// temporarily take priority; the alert must never swallow start/done
    /// cues from an agent.
    func showQuotaAlert(providerName: String,
                        subtitle: String,
                        detail: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
#if DEBUG
            guard !self.suppressQuotaAlertsForTests else {
                Logger.shared.logInfo("TestUI: quota alert suppressed during deterministic test")
                return
            }
#endif
            // Compose an attention-style scene so the renderer has content.
            let scene = IslandScene(
                mode: .attention,
                title: providerName.uppercased(),
                subtitle: subtitle,
                icon: "robot_attention",
                animation: .alert,
                priority: 50, // above agent attention (40) while shown
                appId: "quota")
            self.container.currentScene = scene
            self.container.signalText = detail
            self.hoverExpanded = false
            self.hoverCollapseTimer?.invalidate()
            self.hoverCollapseTimer = nil
            self.stopActiveAgentRotation()
            self.setMode(.quotaAlert)
            self.autoCollapseAt = nil // persistent until user clicks
        }
    }

    /// Convenience: quota-window recovery alert.
    func showQuotaRecovery(providerName: String,
                           windowName: String,
                           remainingPercent: Double) {
        showQuotaAlert(providerName: providerName,
                       subtitle: "额度已恢复",
                       detail: "\(windowName)额度已恢复(\(Int(remainingPercent.rounded()))%)")
    }

    /// Dismisses a quota alert, returning to the scene-driven display.
    private func dismissQuotaAlert() {
        guard currentMode == .quotaAlert else { return }
        container.signalText = nil
        refreshEntries()
        refreshScenes()
        applyBestScene()
    }

    // MARK: - State → Display

    private func refreshEntries() {
        guard let engine = engine else { return }
        var updated: [IslandEntry] = []
        for app in apps {
            let snap = engine.stateForApp(app)
            let running = engine.isAppRunning(app)
            updated.append(IslandEntry(app: app, snapshot: snap, isRunning: running))
        }
        container.entries = updated
        container.featured = updated.max(by: {
            $0.snapshot.status.uiPriority < $1.snapshot.status.uiPriority
        }) ?? updated.first
    }

    // MARK: - Scene-driven presentation (product layer)

    /// Rebuilds the actionable scene array from the engine's current states.
    /// The array is the single source of truth the renderer displays. Feeds
    /// both the container (for drawing) and the rotation manager (for picking).
    private func refreshScenes() {
        guard let engine = engine else { return }
        container.scenes = presentationEngine.presentScenes(for: apps, engine: engine)
        rotationManager.updateScenes(container.scenes)
    }

    /// Presents the current scene chosen by the rotation manager:
    /// - no actionable scenes → dormant (hidden) unless the user is hovering
    ///   (peek keeps the last scene visible)
    /// - attention → hold (exclusive, no rotation)
    /// - celebration → brief showcase, ~3s then auto-collapse
    /// - active → show; multiple active (no attention) → 2s rotation via
    ///   IslandRotationManager
    private func applyBestScene() {
        guard let best = rotationManager.currentScene() else {
            // Nothing actionable. Hidden, unless the user is hovering (peek).
            if !hoverExpanded {
                rotationManager.stopRotation()
                // 全部 idle → 重置轮换静默标志,下次有工作再正常展示。
                rotationExhausted = false
                setMode(.hidden)
            }
            return
        }

        // Sync the renderer's scene + featured entry (for click-through).
        container.currentScene = best
        if let entry = container.entries.first(where: { $0.app.id == best.appId }) {
            container.featured = entry
        }

        switch best.mode {
        case .attention:
            // Persistent until resolved (exclusive — no rotation).
            // Attention 需要用户处理 → 唤醒岛。
            rotationExhausted = false
            hoverExpanded = false
            hoverCollapseTimer?.invalidate()
            hoverCollapseTimer = nil
            rotationManager.stopRotation()
            setMode(.attention)
            autoCollapseAt = nil
        case .celebration:
            // Brief showcase then collapse.
            // 完成庆祝 → 唤醒岛(短暂展示后自动收起)。
            rotationExhausted = false
            hoverExpanded = false
            hoverCollapseTimer?.invalidate()
            hoverCollapseTimer = nil
            rotationManager.stopRotation()
            setMode(.expanded)
            autoCollapseAt = Date().addingTimeInterval(3)
        case .active:
            // 轮换一轮已展示并退出后,持续 working 不再重新打扰——
            // 否则收起 → working 重新确认 → 又展开,无限循环。
            if rotationExhausted {
                Logger.shared.logInfo("applyBestScene: rotation exhausted, stay hidden (working continues)")
                return
            }
            // Persistent while working; the user may want to follow it.
            hoverExpanded = false
            hoverCollapseTimer?.invalidate()
            hoverCollapseTimer = nil
            setMode(.expanded)
            if rotationManager.shouldRotate {
                // Multiple active agents (no attention) → rotate every 2s via
                // the rotation manager (one full round, then auto-dismiss).
                autoCollapseAt = nil
                rotationManager.startRotation { [weak self] scene in
                guard let self = self else { return }
                // RotationManager 完整展示一轮后回调 nil → 收起岛,不常驻。
                guard let scene = scene else {
                    Logger.shared.logInfo("FloatingIsland rotation complete → dismiss")
                    self.rotationExhausted = true
                    self.hide()
                    return
                }
                let currentId = self.container.currentScene?.appId ?? "(none)"
                // Skip if already showing this scene (first tick after start).
                if currentId == scene.appId {
                    return
                }
                // Cross-fade to the next scene without changing geometry —
                // the island stays put, only the content swaps. Captures the
                // current window geometry (which the engine then holds
                // constant through both fade-out and fade-in steps).
                let size = self.frame.size
                let radius = min(size.width, size.height) / 2
                if let entry = self.container.entries.first(where: { $0.app.id == scene.appId }) {
                    self.container.featured = entry
                }
                Logger.shared.logInfo("rotation: current=\(currentId) → next=\(scene.appId) (geometry held: \(Int(size.width))×\(Int(size.height)), r=\(Int(radius)))")
                self.sceneTransition.crossFade(
                    to: scene,
                    currentGeometry: (size: size, cornerRadius: radius)
                )
            }
            } else {
                // 单 agent working:通知式展示 2 秒后自动收起(不常驻)。
                // 收起后该 agent 状态不变 → 无新事件 → 岛保持 hidden;
                // 新状态(其他 agent 开始/attention/completed)会重新展示。
                autoCollapseAt = Date().addingTimeInterval(2)
            }
        case .dormant, .peek:
            break // not actionable; nothing to present
        }
    }

    // MARK: - Mode Transition (same NSPanel, resize only)

    /// 状态 → 形变：把目标几何交给 `IslandAnimationEngine`，由它逐帧驱动
    /// frame + cornerRadius 同步插值（Dynamic Island 形变）。
    ///
    /// 渲染态规则：收起（→ hidden）时保留上一态继续绘制，使收缩过程可见；
    /// 其余情况立即切到目标态渲染。
    private func setMode(_ mode: IslandDisplayMode) {
        // A state/signal event can reopen the island after hide() has stopped
        // the content timer and ordered the panel out. These paths call
        // setMode directly (not show()), so restore both prerequisites here.
        // Do this before the same-mode guard: a completion cue can replace an
        // already-expanded working card while the timer is still stopped.
        if mode != .hidden {
            orderFrontRegardless()
            ensureAnimTimerRunning()
        }
        guard currentMode != mode else { return }
        // 显式切换到可见表面（expanded / attention / quotaAlert）意味着
        // 一次新的展示意图：若此时正有 collapse 在途（hide() 刚被点击触发），
        // 必须清除 pendingHide——否则幂等守卫会永久拦截后续 hide()，
        // 表现为“点一下收不起来”。show() 本身也会重置 pendingHide，
        // 但 applyBestScene / showQuotaRecovery 只走 setMode，不经过 show()。
        if mode != .hidden {
            pendingHide = false
        }
        let from = currentMode
        currentMode = mode
        Logger.shared.logInfo("FloatingIsland \(from) -> \(mode)")

        let targetSize: NSSize
        switch mode {
        case .hidden:     targetSize = hiddenSize
        case .expanded:   targetSize = expandedSize
        case .attention:  targetSize = attentionSize
        case .quotaAlert: targetSize = attentionSize
        // .collapsing 不是 setMode 的目标态——setMode 只处理显式表面切换,
        // hide() 直接用引擎序列收缩。给个保守值(不会真正用到,因为
        // setMode 的入口 guard 会拒绝 .collapsing 目标)。
        case .collapsing: targetSize = hiddenSize
        }

        // Dynamic Island 形变语义：圆角 = min(w,h)/2，引擎逐帧插值，
        // 保证 frame 与圆角严格同步（不再瞬间跳变）。
        let targetRadius = min(targetSize.width, targetSize.height) / 2

        let phase: IslandPhase = (mode == .hidden) ? .collapsing : .awakening
        let target = IslandMorphTarget(size: targetSize,
                                       cornerRadius: targetRadius,
                                       shadowOpacity: 0,
                                       blurOpacity: 0)

        // 收起时保留上一态继续绘制（可见收缩动画）；其余立即切目标态。
        let renderMode: IslandDisplayMode = (mode == .hidden) ? from : mode
        container.mode = renderMode

        animationEngine.morph(to: target, phase: phase, duration: 0.3)
    }

    // MARK: - Morph application (v11)

    /// 引擎每帧回调：把插值态应用到窗口几何 + container 显示属性。
    private func applyMorph(_ state: IslandMorphState) {
        guard let screen = NSScreen.main else { return }
        let x = screen.frame.midX - state.size.width / 2
        let y = screen.frame.maxY - state.size.height
        // display: true 同步提交：和 setFrame 内的 draw 原子绑定,避免异步合成
        // 与后台 OCR(全屏 CGWindowListCreateImage)触发的 WindowServer 重绘
        // 互相撕扯导致"划线/错位"伪影。display: false 在 OCR 并发场景下会
        // 出现 vsync 帧丢弃,表现为文字被横线划过、像素错位。同步提交阻塞
        // 主线程 ~0.5ms,可接受。
        setFrame(NSRect(x: x, y: y, width: state.size.width, height: state.size.height),
                 display: true)
        container.morphCornerRadius = state.cornerRadius
        container.morphShadowOpacity = state.shadowOpacity
        container.morphBlurOpacity = state.blurOpacity
        container.contentAlpha = state.contentAlpha
        // 一次统一的绘制标记(属性 didSet 已不再各自触发重绘)。
        container.needsDisplay = true
    }

    /// 引擎形变完成回调：收起时切到 hidden 渲染态 + 装 hover 命中区；
    /// 其余情况做最终几何确认 + 重算 tracking area。
    ///
    /// 命中区安装时机修复（hover 不响应根因）：hide() 的序列是
    ///   contentFadeOut → collapsing → dormant
    /// 三个阶段。每次阶段完成都调用本回调。.collapsing 完成时
    /// `installHoverHitRegion()` 把 frame 设到 100×80；但接着 .dormant
    /// 阶段的 `applyMorph()` 会把 frame 插值回 hiddenSize(100×4)，把
    /// hover 命中区改小到几乎不可命中。修复：在 .dormant 完成时也调用
    /// `installHoverHitRegion()`（重新把 frame 装回 100×80），保证整个
    /// 隐藏周期里命中区稳定。
    ///
    /// **不调用 `orderOut()`**：原来 finishMorph(.collapsing) 在 hide 序列
    /// 末尾调用 orderOut 把 panel 移出屏幕——但 orderOut 之后 NSWindow
    /// 不再接受任何鼠标事件。即便 frame 是 100×80，orderOut'd 状态的
    /// panel 鼠标滑上去也不会触发 mouseEntered，悬浮岛永远不展开。
    /// 正确做法是让 panel 保持 on-screen：4px sliver 视觉上作为「岛存在」
    /// 提示，76px 不可见区域作为 hover 命中区；alpha=0/容器 mode=hidden
    /// 已经让内容完全不可见，不需要 orderOut。CPU 层面 animTimer 已
    /// invalidate，draw() 在 hidden 模式 early return，开销可控。
    private func finishMorph(_ phase: IslandPhase) {
        switch phase {
        case .collapsing:
            container.mode = .hidden
            installHoverHitRegion()
        case .dormant:
            container.mode = .hidden
            installHoverHitRegion()
            // hide() 发起的收起序列：把模式翻到 hidden 并停掉动画计时器。
            // 不 orderOut，让 panel 保留在屏幕空间以接收 hover 事件。
            if pendingHide {
                pendingHide = false
                currentMode = .hidden
                animTimer?.invalidate()
            }
        default:
            break
        }
        container.frame = contentView?.bounds ?? .zero
        container.updateTrackingAreas()
        container.needsDisplay = true
    }

    // MARK: - Positioning & Hover Hit Region

    private func positionTopCenter() {
        guard let screen = NSScreen.main else { return }
        let size = hiddenSize
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        // The 4px sliver is impossible to hit with a cursor — install a
        // wider invisible hit region for hover-to-peek.
        installHoverHitRegion()
    }

    /// Expands the window's interactive hit area downward while in hidden mode
    /// so the user can actually hit the 4px sliver with the mouse. The
    /// expanded area is *invisible* (alpha = 0, no draw) — only mouse events
    /// are absorbed. When the user hovers, `FloatingIsland` peeks the island
    /// (hidden → expanded) and the visible region grows to the full card.
    ///
    /// Implementation: we resize the contentView taller and offset the actual
    /// visible content area to remain at the top. The container draws nothing
    /// when `mode == .hidden`, so the extra height is transparent regardless.
    private func installHoverHitRegion() {
        // Allow installation during both .hidden and .collapsing — the latter
        // is the entire duration of `hide()`'s morph sequence, when currentMode
        // is set to .collapsing by hide() itself. installHoverHitRegion is
        // called from finishMorph(.collapsing/.dormant); we need it to run
        // even before currentMode finally transitions to .hidden (which only
        // happens after orderOut in the .dormant branch). Without accepting
        // .collapsing here, the 100×80 hit region never gets installed during
        // the hide morph and gets overridden by the .dormant phase's
        // applyMorph — symptom: the panel stays at 100×4 (un-hoverable).
        guard currentMode == .hidden || currentMode == .collapsing else { return }
        // Make the window's frame taller — visually still 4px because the
        // container's draw is empty for .hidden. The hit region must NOT
        // extend past the menu bar: the user's browser (and any other
        // app) sits immediately below the menu bar, and an oversized hit
        // region steals mouse events from that app. Size the hover region
        // to the actual menu bar height (= screen.frame.maxY - visibleFrame.maxY)
        // so the cursor only triggers the island while it is over the menu
        // bar itself. On this display that's 30 pt; previous hard-coded 80
        // px extended ~50 px below the menu bar, intercepting clicks meant
        // for the browser.
        let screenFrame: NSRect = NSScreen.main?.frame ?? .zero
        let menuBarHeight: CGFloat = {
            guard let screen = NSScreen.main else { return 30 }
            return screen.frame.maxY - screen.visibleFrame.maxY
        }()
        let hoverHeight: CGFloat = menuBarHeight
        // Anchor the visible 4px sliver to the screen top; extend downward
        // by exactly menuBarHeight (so the bottom of the hit region is flush
        // with the menu bar bottom — the cursor leaves the region as soon
        // as it crosses into app content).
        let x = screenFrame.midX - hiddenSize.width / 2
        let y = screenFrame.maxY - hoverHeight
        let hoverFrame = NSRect(x: x, y: y, width: hiddenSize.width, height: hoverHeight)
        // Only resize if actually different (avoid resize storms from mouseMoved).
        if frame.size != hoverFrame.size || frame.origin != hoverFrame.origin {
            setFrame(hoverFrame, display: false)
        }
        // 同步动画引擎到窗口真实几何(100×80 命中区,而非 100×4 引擎残留):
        // 否则 hover 展开时引擎从 100×4 起步,首帧把 100×80 的窗口猛缩成
        // 4px 细条再长回 260×64 —— 视觉上的「闪两下」。contentAlpha=0
        // 保持 hidden 语义(命中区不可见)。
        let radius = hoverFrame.height / 2
        animationEngine.syncCurrent(IslandMorphState(size: hoverFrame.size,
                                                     cornerRadius: radius,
                                                     shadowOpacity: 0,
                                                     blurOpacity: 0,
                                                     contentAlpha: 0))
    }

    // MARK: - Animation Timer

    private func startAnimTimer() {
        animTimer?.invalidate()
        // 内容动画(能量条流动/眨眼/呼吸)的帧计数器。频率 15Hz——能量条
        // 流动足够顺滑,同时把 idle/hidden 态的重绘负载压到最低。几何形变
        // 由 IslandAnimationEngine(CVDisplayLink, vsync 对齐)独立驱动。
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
    }

    private func ensureAnimTimerRunning() {
        guard animTimer?.isValid != true else { return }
        startAnimTimer()
        Logger.shared.logInfo("FloatingIsland animation timer restored")
    }

    private func tick() {
        // 只有当岛实际在显示内容(expanded/attention/quotaAlert)时才推进
        // 内容帧 + 重绘。hidden 态 draw() 是空的,推进 animFrame 只会触发
        // 30 次无意义的整窗重绘(原 30Hz × needsDisplay 是 CPU 高的元凶)。
        let showingContent = (currentMode != .hidden)
        if showingContent {
            container.animFrame += 1
            // blinkOn(attention 边框脉冲):15Hz 下 7 tick ≈ 0.47s 翻转一次,
            // 保持原 ~0.45s 的闪烁节律。
            if container.animFrame % 7 == 0 {
                container.blinkOn.toggle()
            }
        }
        // Auto-collapse check (paused while hovering)——与内容帧无关,始终检查。
        // - autoCollapseAt is set by .completed (3s showcase) — honors it.
        // - hoverCollapseTimer is set by mouseExited (2s after hover peek) — separate path.
        // working/attention set autoCollapseAt = nil, so they stay forever.
        if let collapseAt = autoCollapseAt, !isHovering {
            let now = Date()
            if now > collapseAt, currentMode == .expanded {
                autoCollapseAt = nil
                completionOverrideAppId = nil
                completionOverrideUntil = nil
                Logger.shared.logInfo("FloatingIsland auto-collapse deadline reached")
                setMode(.hidden)
            }
        }
    }

    // MARK: - Hover → Peek

    /// Returns the list of agents that deserve the user's attention right now:
    /// only those with `working` or `needsAttention` status. Sorted so that
    /// `needsAttention` (user must act) precedes `working` (autonomous work).
    /// Idle / completed agents are intentionally excluded — the island is a
    /// focus window for *current* activity, not a status dashboard.
    private func activeAgents() -> [IslandEntry] {
#if DEBUG
        // DEBUG HOOK: `defaults write ... TestMultiActive N` forces the first
        // N entries to be returned as "active" — used to verify the rotation
        // path without needing real multi-agent activity. Isolated under
        // #if DEBUG: compiled out in release builds (build.sh does not
        // define DEBUG), zero runtime cost in the shipped app.
        let testCount = UserDefaults.standard.integer(forKey: "TestMultiActive")
        if testCount >= 2 {
            return Array(container.entries.prefix(min(testCount, container.entries.count))
                .map { entry in
                    IslandEntry(app: entry.app,
                                snapshot: StateSnapshot(status: .working,
                                                       evidenceSource: .ax,
                                                       confidence: 1.0),
                                isRunning: true)
            })
        }
#endif
        // Scene-driven: only agents the presentation engine marked actionable
        // (active / attention / celebration) qualify. Sorting uses the scene's
        // own priority (mirrors uiPriority: attention > working > completed).
        let actionable = container.scenes.filter(\.isActionable)
        let priorityByID = Dictionary(uniqueKeysWithValues: actionable.map { ($0.appId, $0.priority) })
        return container.entries
            .filter { priorityByID[$0.app.id] != nil }
            .sorted { (priorityByID[$0.app.id] ?? 0) > (priorityByID[$1.app.id] ?? 0) }
    }

    /// Sets the featured agent without disturbing the engine-driven featured
    /// ranking — used by hover rotation to "manually" pick a working agent.
    /// Caller is responsible for clearing the override (e.g. on mouseExit /
    /// state-event path) by calling `refreshEntries()`.
    private func displayAgent(_ entry: IslandEntry) {
        container.featured = entry
    }

    /// Starts rotating through active agents every 2 seconds. Idempotent:
    /// always cancels any existing timer first. Only schedules a timer when
    /// there are ≥2 active agents — single active agent stays put.
    ///
    /// Uses a recursive `DispatchQueue.global().asyncAfter` chain instead of
    /// `Timer.scheduledTimer` or `DispatchSourceTimer` because NSPanel in a
    /// menu-bar app doesn't reliably pump main-RunLoop timers.
    private func startActiveAgentRotation() {
        stopActiveAgentRotation()
        let agents = activeAgents()
        guard agents.count > 1 else { return }
        activeAgentIndex = 0
        displayAgent(agents[0])
        rotationActive = true
        Logger.shared.logInfo("FloatingIsland startActiveAgentRotation: agents=\(agents.count) first=\(agents[0].app.id)")
        scheduleNextRotationTick()
    }

    /// Schedules the next 2-second rotation tick on a global background queue
    /// so it fires independently of any RunLoop. Each tick re-schedules the
    /// next one (recursion via asyncAfter) until `rotationActive` is cleared.
    private func scheduleNextRotationTick() {
        guard rotationActive else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
            // Hop to main for the display update (NSView mutations must be on main).
            DispatchQueue.main.async {
                self?.activeAgentTick()
            }
        }
    }

    private func activeAgentTick() {
        // Hover-peek rotation only: the scene-driven rotation now lives in
        // IslandRotationManager. This path serves the hover multi-agent peek.
        let current = activeAgents()
        guard !current.isEmpty else {
            stopActiveAgentRotation()
            return
        }
        activeAgentIndex = (activeAgentIndex + 1) % current.count
        let entry = current[activeAgentIndex]
        displayAgent(entry)
        // Keep the rendered scene in sync with the rotated agent: the draw
        // layer ONLY renders IslandScene.
        if let scene = container.scenes.first(where: { $0.appId == entry.app.id }) {
            container.currentScene = scene
        } else {
            container.currentScene = presentationEngine.peekScene(for: entry.app)
        }
        Logger.shared.logInfo("FloatingIsland rotate → \(entry.app.id)")
        // Schedule the next tick (only if still active).
        scheduleNextRotationTick()
    }

    /// Cancels the active-agent rotation by clearing the rotationActive flag.
    /// The next scheduled `asyncAfter` block will see `false` and exit without
    /// re-scheduling. Does NOT touch `hoverExpanded` — that flag is owned by
    /// mouseEntered/mouseExited for hover-peek collapse timing.
    private func stopActiveAgentRotation() {
        rotationActive = false
    }

    /// Schedules a collapse back to hidden `delay` seconds from now, **only**
    /// if the island is still in hover-expanded mode and not currently being
    /// hovered. The state machine takes precedence: if a real `working`
    /// transition fires before the timer fires, `reactToStateChange` will
    /// have cleared `hoverExpanded` and invalidated the timer already.
    private func scheduleHoverCollapse(after delay: TimeInterval) {
        hoverCollapseTimer?.invalidate()
        hoverCollapseTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Only collapse if we're still in the hover-peek state. Real
                // working/attention states would have cleared hoverExpanded
                // and the timer; this is the safe fallback.
                if self.hoverExpanded && !self.isHovering, self.currentMode == .expanded {
                    self.hoverExpanded = false
                    self.setMode(.hidden)
                }
            }
        }
    }
}

// MARK: - FloatingIslandViewDelegate

extension FloatingIsland: FloatingIslandViewDelegate {

    func islandViewMouseEntered(_ view: FloatingIslandView) {
        isHovering = true
        container.isHovering = true
        // Cancel any pending hover-driven collapse.
        hoverCollapseTimer?.invalidate()
        hoverCollapseTimer = nil

        // Hover must not override a quota alert (the user might hover to read
        // the alert text). Agent events may still take priority.
        if currentMode == .quotaAlert {
            return
        }

        // Pull the freshest engine state before picking what to show: the
        // cached `container.entries` can lag one poll behind (a working agent
        // may not have flipped yet), which caused hover to show an idle agent.
        refreshEntries()
        refreshScenes()

        // v8: the island is a focus window for *current* activity. If a real
        // working/attention state is already showing (state-event-driven),
        // don't override the featured agent or start rotation — the state
        // machine picks the right one. Just stop any leftover rotation timer.
        if currentMode == .expanded || currentMode == .attention {
            // BUT: if we (hover-peek) are the reason it's already expanded,
            // don't tear down our own rotation. The NSPanel tracking area
            // sometimes re-fires mouseEntered after the bounds-animation
            // settles — this guard prevents that self-stop.
            if !hoverExpanded {
                stopActiveAgentRotation()
            }
            return
        }

        // Hidden → peek path. Prefer active agents (working/attention); if none
        // are active, peek the highest-priority *running* agent — a running app
        // is far more relevant than an arbitrary idle entry, and an idle app
        // that happens to be first in the list must NOT win over one that's
        // actually doing something.
        let agents = activeAgents()
        let peekTarget: IslandEntry
        if let first = agents.first {
            peekTarget = first
        } else if let running = container.entries.first(where: { $0.isRunning }) {
            peekTarget = running
        } else if let featured = container.featured {
            peekTarget = featured
        } else if let first = container.entries.first {
            peekTarget = first
        } else {
            Logger.shared.logInfo("FloatingIsland hover: no entries at all, staying hidden")
            return
        }

        hoverExpanded = true
        displayAgent(peekTarget)
        // Scene-driven: the draw layer ONLY renders IslandScene — it must never
        // receive nil. If the peek target has no actionable scene (idle agent),
        // request a product-layer preview scene from the presentation engine.
        if let scene = container.scenes.first(where: { $0.appId == peekTarget.app.id }) {
            container.currentScene = scene
        } else {
            container.currentScene = presentationEngine.peekScene(for: peekTarget.app)
        }
        expandFromHover()
        // ≥2 active → rotate every 2s. Single active → stay put.
        if agents.count > 1 {
            startActiveAgentRotation()
        } else {
            stopActiveAgentRotation()
        }
        Logger.shared.logInfo("FloatingIsland hover-peek showing [\(peekTarget.app.id)] (active=\(agents.count))")
    }

    /// Hover 触发的缓慢渐进展开(与 show() 的展开节奏一致,而非 setMode 的
    /// 单段 0.3s 突闪):
    /// - step1 awakening 300ms:当前几何(100×80 命中区,已由
    ///   installHoverHitRegion 同步到引擎)平滑展开到 expandedSize,
    ///   contentAlpha 保持 0 —— 岛先"长"出来,内容仍隐藏
    /// - step2 contentFadeIn 150ms:contentAlpha 0→1 —— 内容最后淡入
    /// 总计 ~450ms。取消机制保证展开中途来 hide/click 可作废本序列。
    private func expandFromHover() {
        // Hover may intentionally interrupt an in-flight hide(). The old
        // sequence is cancelled by the new morph below, so its pendingHide
        // completion will never run; release the guard here for the next click.
        pendingHide = false
        let currentSize = self.frame.size
        let currentRadius = min(currentSize.width, currentSize.height) / 2
        let fullRadius = min(expandedSize.width, expandedSize.height) / 2
        animationEngine.syncCurrent(IslandMorphState(size: currentSize,
                                                     cornerRadius: currentRadius,
                                                     shadowOpacity: 0,
                                                     blurOpacity: 0,
                                                     contentAlpha: 0))
        currentMode = .expanded
        container.mode = .expanded
        Logger.shared.logInfo("FloatingIsland hover expand (slow: 300ms morph + 150ms contentFadeIn)")
        animationEngine.morphSequence([
            IslandMorphStep(target: IslandMorphTarget(size: expandedSize,
                                                      cornerRadius: fullRadius,
                                                      contentAlpha: 0),
                            phase: .awakening, duration: 0.3),
            IslandMorphStep(target: IslandMorphTarget(size: expandedSize,
                                                      cornerRadius: fullRadius,
                                                      contentAlpha: 1),
                            phase: .contentFadeIn, duration: 0.15)
        ])
    }

    func islandViewMouseExited(_ view: FloatingIslandView) {
        isHovering = false
        container.isHovering = false

        // Debounce the exit handling by 0.3s. NSPanel's tracking area fires
        // mouseExited spuriously while the frame is animating from hidden
        // (100×80 hit region) to expanded (260×64) — the bounds change
        // mid-animation and the cursor briefly appears "outside" the new
        // tracking rect. If the user is still hovering, a follow-up
        // mouseEntered will reset `isHovering` to true and cancel this.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, !self.isHovering else { return }
            // Stop the rotation now that we're sure the cursor really left.
            self.stopActiveAgentRotation()

            // Restore featured to the engine's ranked pick, in case hover had
            // overridden it. (refreshEntries re-applies uiPriority ordering.)
            self.refreshEntries()

            // Only schedule collapse if we're in the hover-peek state. Real
            // working/attention have already cleared hoverExpanded; completed
            // uses its own autoCollapseAt path.
            if self.hoverExpanded, self.currentMode == .expanded {
                self.scheduleHoverCollapse(after: 2.0)
            }
        }
    }

    func islandView(_ view: FloatingIslandView, didClickAppId id: String) {
        // Quota alert: clicking dismisses the alert instead of activating an app.
        if currentMode == .quotaAlert {
            Logger.shared.logInfo("FloatingIsland: quota alert clicked → dismiss")
            dismissQuotaAlert()
            return
        }
        guard let app = apps.first(where: { $0.id == id }) else { return }
        Logger.shared.logInfo("FloatingIsland: click → activate \(app.id)")
        AppActivator.activate(bundleId: app.bundleId)
    }
}

// MARK: - SceneSetter（IslandSceneTransition 回调）

extension FloatingIsland: SceneSetter {
    /// Replaces the rendered scene at the fade-out → fade-in boundary during
    /// a cross-fade. The container's `currentScene` setter already triggers
    /// `needsDisplay`, so the swap is picked up on the next redraw.
    func setCurrentScene(_ scene: IslandScene) {
        container.currentScene = scene
    }
}
