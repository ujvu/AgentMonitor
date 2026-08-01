import Cocoa

// MARK: - PixelAgentType

/// Maps a watched app to the pixel-art character that represents it in the
/// floating island's avatar slot. Anything we don't know falls back to
/// `unknown`, which the renderer draws as the generic robot head.
///
/// PixelAgentVisual is a pure presentation layer — it knows nothing about
/// `AgentStatus` / `IslandMode` / fusion / etc. The caller decides which
/// drawing function to invoke (idle / working / completed); this enum is
/// just the "what character" lookup.
enum PixelAgentType {
    case zcode
    case workbuddy
    case qwenwork
    case chatgpt
    case unknown

    /// Resolve an app id to a pixel-agent type. New apps default to
    /// `.unknown` (which renders the legacy generic robot head) until a
    /// dedicated character is designed for them.
    static func resolve(appId: String) -> PixelAgentType {
        switch appId {
        case "zcode":      return .zcode
        case "workbuddy":  return .workbuddy
        case "qwenwork":   return .qwenwork
        case "chatgpt":    return .chatgpt
        default:           return .unknown
        }
    }
}

// MARK: - PixelAgentVisual

/// Pixel-art characters for the avatar slot. All characters share the same
/// 8×8 cell convention as `PixelTheme.drawRobotHead`: a unit `s =
/// min(rect.width, rect.height)/10` and integer multiples thereof.
///
/// Animation principles (Phase 4 second pass):
/// - **Pixel-friendly** motion only: position offsets, blink/scale pulses,
///   brightness modulations, discrete frame swaps. NO rotation, NO
///   transforms, NO sub-pixel skews — those fight the pixel grid.
/// - **Independent phase**: each character reads `phase = fractional part of
///   Date().timeIntervalSinceReferenceDate * (own cadence) + (own offset)`,
///   so two characters running at the same speed never sync-jitter. No
///   per-character state — phase is derived purely from wall-clock time.
/// - **Completion animations are intentionally NOT implemented in this
///   pass** (Phase 4 second-pass scope: idle + working only).
enum PixelAgentVisual {

    // MARK: - Phase derivation（独立时钟 + 每角色偏移，避免同步抖动）

    /// Returns a phase in [0, 1) cycling at `period` seconds, advanced by
    /// `offsetSeconds` per character so simultaneous drawing calls don't
    /// land on the same frame.
    private static func phase(period: Double, offset: Double) -> Double {
        let now = Date().timeIntervalSinceReferenceDate
        var p = (now + offset).truncatingRemainder(dividingBy: period)
        if p < 0 { p += period }
        return p / period
    }

    /// Frame index for discrete frame-swap animations (e.g. 2-frame wing
    /// flap). Returns `floor(phase * frameCount)`.
    private static func frame(in phase: Double, frameCount: Int) -> Int {
        let f = Int((phase * Double(frameCount)).rounded(.down))
        return min(max(f, 0), frameCount - 1)
    }

    /// Returns 1.0 when `phase` is within the first `onFraction` of the
    /// cycle (the "visible" half of a blink), else 0.0. Used for hard
    /// pixel on/off blinks (e.g. eyes).
    private static func blink(in phase: Double, onFraction: Double = 0.3) -> Bool {
        return phase < onFraction
    }

    /// Smooth 0→1→0 sine pulse over one period. Used for brightness
    /// modulation (e.g. unicorn horn glow, paw-print sparkle).
    private static func pulse(in phase: Double) -> Double {
        return 0.5 + 0.5 * sin(phase * .pi * 2)
    }

    // MARK: - Shared pixel-rect helper

    /// Produces a child NSRect inside `rect` at proportional offsets. The
    /// caller multiplies by their chosen `s` so all characters share the
    /// same pixel grid as `PixelTheme.drawRobotHead`.
    private static func pixelRect(_ ox: CGFloat,
                                 _ oy: CGFloat,
                                 _ w: CGFloat,
                                 _ h: CGFloat,
                                 in rect: NSRect,
                                 s: CGFloat) -> NSRect {
        return NSRect(x: rect.minX + ox * s,
                      y: rect.minY + oy * s,
                      width: w * s,
                      height: h * s)
    }

    // MARK: - Public dispatch

    /// Draws the idle pose of the pixel agent for `appId`.
    /// PixelAgentVisual does not know what an "idle" means semantically;
    /// the caller (FloatingIsland) decides which draw function to invoke
    /// based on `scene.mode` / `scene.animation`.
    /// `phase` drives the idle micro-animation (blink / ear motion / wing
    /// sway / horn glow). Pass `idlePhase(for:)` for the calm ~2.4s idle
    /// cadence.
    static func drawIdle(in rect: NSRect, color: NSColor, appId: String, phase: Double) {
        switch PixelAgentType.resolve(appId: appId) {
        case .zcode:     drawCat(in: rect, color: color, working: false, phase: phase)
        case .workbuddy: drawWolf(in: rect, color: color, working: false, phase: phase)
        case .qwenwork:  drawPhoenix(in: rect, color: color, working: false, phase: phase)
        case .chatgpt:   drawUnicorn(in: rect, color: color, working: false, phase: phase)
        case .unknown:   PixelTheme.drawRobotHead(in: rect, color: color, blink: false)
        }
    }

    /// Idle micro-animation phase: slow cycle (~2.2–2.8s per character) with
    /// per-agent offsets so simultaneous idle agents never sync-jitter.
    /// Derived from wall-clock time — no animFrame dependency.
    static func idlePhase(for appId: String) -> Double {
        switch PixelAgentType.resolve(appId: appId) {
        case .zcode:     return phase(period: 2.4, offset: 0.00)
        case .workbuddy: return phase(period: 2.8, offset: 0.21)
        case .qwenwork:  return phase(period: 2.2, offset: 0.43)
        case .chatgpt:   return phase(period: 2.6, offset: 0.67)
        case .unknown:   return phase(period: 2.4, offset: 0.00)
        }
    }

    /// Draws the working pose of the pixel agent for `appId`. The `phase`
    /// argument is the working-animation phase in [0, 1); the renderer
    /// derives it from wall-clock time at call site so every drawing call
    /// gets an independent, non-synchronized value.
    static func drawWorking(in rect: NSRect, color: NSColor, appId: String, phase: Double) {
        switch PixelAgentType.resolve(appId: appId) {
        case .zcode:     drawCat(in: rect, color: color, working: true, phase: phase)
        case .workbuddy: drawWolf(in: rect, color: color, working: true, phase: phase)
        case .qwenwork:  drawPhoenix(in: rect, color: color, working: true, phase: phase)
        case .chatgpt:   drawUnicorn(in: rect, color: color, working: true, phase: phase)
        case .unknown:   PixelTheme.drawRobotHead(in: rect, color: color, blink: phase < 0.5)
        }
    }

    /// Draws the completed-pose of the pixel agent for `appId`. `frame` is
    /// the discrete frame index (typically `floor(completedPhase *
    /// frameCount)`); the renderer only uses integer steps for completed
    /// animations — completed poses are celebratory, not continuous.
    static func drawCompleted(in rect: NSRect, color: NSColor, appId: String, frame: Int) {
        switch PixelAgentType.resolve(appId: appId) {
        case .zcode:     drawCatCompleted(in: rect, color: color, frame: frame)
        case .workbuddy: drawWolfCompleted(in: rect, color: color, frame: frame)
        case .qwenwork:  drawPhoenixCompleted(in: rect, color: color, frame: frame)
        case .chatgpt:   drawUnicornCompleted(in: rect, color: color, frame: frame)
        case .unknown:   PixelTheme.drawRobotHead(in: rect, color: color, blink: false)
        }
    }

    /// Convenience accessor for the completed-animation phase (independent
    /// from workingPhase — different period & offset so a character
    /// cycling through working → completed doesn't visibly hitch on the
    /// transition). Returns a value in [0, 1); callers map it to a frame
    /// index via `completedFrameIndex(phase:frameCount:)`.
    static func completedPhase(for appId: String) -> Double {
        switch PixelAgentType.resolve(appId: appId) {
        case .zcode:     return phase(period: 0.8, offset: 0.13)
        case .workbuddy: return phase(period: 0.9, offset: 0.41)
        case .qwenwork:  return phase(period: 0.7, offset: 0.67)
        case .chatgpt:   return phase(period: 0.6, offset: 0.91)
        case .unknown:   return phase(period: 0.8, offset: 0.00)
        }
    }

    /// Maps a completed-phase in [0, 1) to a discrete frame index in
    /// [0, frameCount). Used by the renderer to step through the
    /// character-specific completed pose sequence (e.g. 4 frames for
    /// zcode's "stars appear one by one" celebration).
    static func completedFrameIndex(phase: Double, frameCount: Int) -> Int {
        return frame(in: phase, frameCount: frameCount)
    }

    /// Convenience accessor for the working-animation phase. Each app id
    /// maps to a different period AND a different clock offset, so two
    /// characters running simultaneously never sync-jitter. The base period
    /// (~1.5s) is slow enough to feel deliberate and fast enough to read as
    /// motion at the 30Hz draw cadence.
    ///
    /// The caller passes the result to `drawWorking(... phase:)`. The
    /// caller does NOT need to manage any state — phase is derived purely
    /// from `Date()` at call time.
    static func workingPhase(for appId: String) -> Double {
        switch PixelAgentType.resolve(appId: appId) {
        case .zcode:     return phase(period: 1.4, offset: 0.00)
        case .workbuddy: return phase(period: 1.0, offset: 0.27)
        case .qwenwork:  return phase(period: 1.7, offset: 0.53)
        case .chatgpt:   return phase(period: 1.2, offset: 0.81)
        case .unknown:   return phase(period: 1.0, offset: 0.00)
        }
    }

    // MARK: - zcode: 像素猫 (idle: 静止; working: 尾巴左右摆 + 眼睛闪烁)

    /// 尖耳 + 圆眼 + 身体 + 长尾摆动。
    /// 工作动画:尾巴用 sin(phase) 算水平位移 ±1px,眼睛每 0.4s 闪一下。
    private static func drawCat(in rect: NSRect, color: NSColor, working: Bool, phase: Double) {
        let s = min(rect.width, rect.height) / 10
        guard s > 1 else { return }
        let ox = rect.midX - s * 4
        let oy = rect.midY - s * 4

        // 尖耳(两片三角)
        PixelTheme.fillRect(pixelRect(0.5, 7.5, 1.5, 1.5, in: rect, s: s), color: color)
        PixelTheme.fillRect(pixelRect(6.0, 7.5, 1.5, 1.5, in: rect, s: s), color: color)
        // 头
        PixelTheme.fillRect(pixelRect(1.0, 4.5, 6.0, 3.5, in: rect, s: s), color: color)
        // 眼睛:working 时 phase blink;idle 时静止
        // 眼睛:working 时眨眼略频繁(onFraction 0.3);idle 时缓慢眨眼
        // (onFraction 0.15,约 2.4s 周期闭 0.36s) —— 生命感微动作。
        let eyeOpen: CGFloat = blink(in: phase, onFraction: working ? 0.3 : 0.15) ? 0.3 : 1.0
        let eyeY = 5.6 + (1 - eyeOpen) * 0.4
        PixelTheme.fillRect(pixelRect(2.0, eyeY, 1.0, eyeOpen, in: rect, s: s), color: PixelTheme.bg)
        PixelTheme.fillRect(pixelRect(5.0, eyeY, 1.0, eyeOpen, in: rect, s: s), color: PixelTheme.bg)
        // 嘴
        PixelTheme.fillRect(pixelRect(3.0, 4.7, 2.0, 0.4, in: rect, s: s), color: PixelTheme.bg)
        // 身体
        PixelTheme.fillRect(pixelRect(1.5, 1.5, 5.0, 3.0, in: rect, s: s), color: color)
        // 尾巴:working 时水平摆动 ±1.0s,idle 时静止
        let tailX = working ? sin(phase * .pi * 2) : 0
        PixelTheme.fillRect(pixelRect(7.0 + tailX, 2.0, 1.5, 0.6, in: rect, s: s), color: color)
        PixelTheme.fillRect(pixelRect(8.0 + tailX, 2.5, 0.8, 0.5, in: rect, s: s), color: color)
    }

    // MARK: - workbuddy: 像素狼 (idle: 静止; working: 耳朵上下抖 + 脚下两脚印闪)

    /// 竖耳 + V 字眼 + 身体。working 时耳朵按 sin 上下 1px,脚下两脚印按 blink 交替亮灭。
    private static func drawWolf(in rect: NSRect, color: NSColor, working: Bool, phase: Double) {
        let s = min(rect.width, rect.height) / 10
        guard s > 1 else { return }
        let ox = rect.midX - s * 4
        let oy = rect.midY - s * 4

        // 竖耳(两片,working 时上下抖)
        // 竖耳:working 时明显抖(±1px);idle 时轻微上下微动(±0.5px)。
        let earOffset: CGFloat = sin(phase * .pi * 2) * (working ? 1.0 : 0.5)
        PixelTheme.fillRect(pixelRect(1.0, 7.0 + earOffset, 1.0, 1.5, in: rect, s: s), color: color)
        PixelTheme.fillRect(pixelRect(6.0, 7.0 + earOffset, 1.0, 1.5, in: rect, s: s), color: color)
        // 头(V 字下沿)
        PixelTheme.fillRect(pixelRect(1.0, 4.5, 6.0, 3.0, in: rect, s: s), color: color)
        PixelTheme.fillRect(pixelRect(2.0, 7.0, 1.0, 0.5, in: rect, s: s), color: color)
        PixelTheme.fillRect(pixelRect(5.0, 7.0, 1.0, 0.5, in: rect, s: s), color: color)
        // V 字眼
        PixelTheme.fillRect(pixelRect(2.0, 5.5, 1.0, 1.0, in: rect, s: s), color: PixelTheme.bg)
        PixelTheme.fillRect(pixelRect(5.0, 5.5, 1.0, 1.0, in: rect, s: s), color: PixelTheme.bg)
        PixelTheme.fillRect(pixelRect(3.0, 5.0, 2.0, 0.4, in: rect, s: s), color: PixelTheme.bg)
        // 身体
        PixelTheme.fillRect(pixelRect(1.5, 1.5, 5.0, 3.0, in: rect, s: s), color: color)
        // 脚印(脚下两片):working 时交替亮灭,idle 不画
        if working {
            let leftLit = blink(in: phase, onFraction: 0.5)
            let rightLit = !leftLit
            if leftLit {
                PixelTheme.fillRect(pixelRect(1.5, 0.3, 1.5, 0.5, in: rect, s: s), color: color)
            }
            if rightLit {
                PixelTheme.fillRect(pixelRect(5.0, 0.3, 1.5, 0.5, in: rect, s: s), color: color)
            }
        }
    }

    // MARK: - qwenwork: 像素凤凰 (idle: 静止; working: 双翅上下挥 + 头顶火苗位移)

    /// 羽冠 + 双翅 + 身体。working 时翅膀按 sin 上下 ±1px,头顶火苗做 ±0.5px 位移。
    private static func drawPhoenix(in rect: NSRect, color: NSColor, working: Bool, phase: Double) {
        let s = min(rect.width, rect.height) / 10
        guard s > 1 else { return }
        let ox = rect.midX - s * 4
        let oy = rect.midY - s * 4

        // 羽冠(头上 3 个小块,working 时左右轻摆)
        // 羽冠:working 时明显摆动;idle 时轻微晃动(±0.15px)。
        let crestOffset: CGFloat = sin(phase * .pi * 2) * (working ? 0.3 : 0.15)
        PixelTheme.fillRect(pixelRect(3.5 + crestOffset, 7.5, 1.0, 1.0, in: rect, s: s), color: color)
        PixelTheme.fillRect(pixelRect(2.5 - crestOffset, 7.0, 0.5, 1.0, in: rect, s: s), color: color)
        PixelTheme.fillRect(pixelRect(5.0 + crestOffset, 7.0, 0.5, 1.0, in: rect, s: s), color: color)
        // 头
        PixelTheme.fillRect(pixelRect(1.5, 5.0, 5.0, 2.5, in: rect, s: s), color: color)
        // 眼
        PixelTheme.fillRect(pixelRect(2.5, 5.7, 0.8, 0.8, in: rect, s: s), color: PixelTheme.bg)
        PixelTheme.fillRect(pixelRect(4.7, 5.7, 0.8, 0.8, in: rect, s: s), color: PixelTheme.bg)
        // 喙
        PixelTheme.fillRect(pixelRect(3.5, 4.5, 1.0, 0.5, in: rect, s: s), color: PixelTheme.bg)
        // 身体
        PixelTheme.fillRect(pixelRect(2.0, 1.5, 4.0, 3.0, in: rect, s: s), color: color)
        // 双翅:working 时上下挥 ±1px,idle 时贴体
        // 双翅:working 时大幅挥动(±1px);idle 时轻微上抬(±0.4px)。
        let wingY: CGFloat = sin(phase * .pi * 2) * (working ? 1.0 : 0.4)
        PixelTheme.fillRect(pixelRect(-0.3, 3.0 + wingY, 1.5, 1.5, in: rect, s: s), color: color)
        PixelTheme.fillRect(pixelRect(6.8, 3.0 + wingY, 1.5, 1.5, in: rect, s: s), color: color)
        // 火苗(头顶,working 时上下漂移)
        if working {
            let flameY = 8.5 + sin(phase * .pi * 2 + .pi / 2) * 0.5
            PixelTheme.fillRect(pixelRect(3.7, flameY, 0.6, 1.0, in: rect, s: s), color: color)
        }
    }

    // MARK: - chatgpt: 像素独角兽 (idle: 静止; working: 独角脉冲亮度 + 圆环位移)

    /// 头 + 独角(中央尖)+ 圆环身。working 时独角亮度按 pulse 调制,圆环做 ±1px 位移。
    private static func drawUnicorn(in rect: NSRect, color: NSColor, working: Bool, phase: Double) {
        let s = min(rect.width, rect.height) / 10
        guard s > 1 else { return }
        let ox = rect.midX - s * 4
        let oy = rect.midY - s * 4

        // 独角(中央尖,working 时按 pulse 调制亮度)
        // 独角:working 时强脉冲(0.4~1.0);idle 时亮度缓慢呼吸(0.85~1.0)。
        let hornBrightness: CGFloat = working ? (0.4 + 0.6 * pulse(in: phase)) : (0.85 + 0.15 * pulse(in: phase))
        let hornAlpha = hornBrightness
        PixelTheme.fillRect(pixelRect(3.7, 7.0, 0.6, 1.5, in: rect, s: s), color: color.withAlphaComponent(hornAlpha))
        // 头
        PixelTheme.fillRect(pixelRect(1.5, 4.5, 5.0, 2.5, in: rect, s: s), color: color)
        // 眼
        PixelTheme.fillRect(pixelRect(2.5, 5.5, 0.8, 0.8, in: rect, s: s), color: PixelTheme.bg)
        PixelTheme.fillRect(pixelRect(4.7, 5.5, 0.8, 0.8, in: rect, s: s), color: PixelTheme.bg)
        // 鼻
        PixelTheme.fillRect(pixelRect(3.7, 4.5, 0.6, 0.4, in: rect, s: s), color: PixelTheme.bg)
        // 圆环身(用一个矩形近似,working 时左右小幅抖动)
        let ringOffset: CGFloat = working ? sin(phase * .pi * 2) * 1.0 : 0
        PixelTheme.fillRect(pixelRect(2.0 + ringOffset, 2.5, 4.0, 2.0, in: rect, s: s), color: color)
        PixelTheme.fillRect(pixelRect(2.5 + ringOffset, 1.5, 3.0, 1.0, in: rect, s: s), color: color)
        PixelTheme.fillRect(pixelRect(3.0 + ringOffset, 0.8, 2.0, 0.7, in: rect, s: s), color: color)
    }

    // MARK: - completed: zcode (弯月眼 + 星粒子闪烁)

    /// Completed 动画:眼睛变成弯月形(∩),头顶 3 颗小星按帧交替亮灭。
    /// 4 帧循环:frame 0 = 静态弯月 + 0 颗星;frame 1 = 1 颗星;frame 2 =
    /// 弯月 + 2 颗星;frame 3 = 弯月 + 3 颗星(全亮)。
    private static func drawCatCompleted(in rect: NSRect, color: NSColor, frame: Int) {
        let s = min(rect.width, rect.height) / 10
        guard s > 1 else { return }

        // 尖耳(同 idle)
        PixelTheme.fillRect(pixelRect(0.5, 7.5, 1.5, 1.5, in: rect, s: s), color: color)
        PixelTheme.fillRect(pixelRect(6.0, 7.5, 1.5, 1.5, in: rect, s: s), color: color)
        // 头
        PixelTheme.fillRect(pixelRect(1.0, 4.5, 6.0, 3.5, in: rect, s: s), color: color)
        // 弯月眼(用两段斜线模拟∩):左右各 1×1 像素 + 角部 0.5×0.5
        PixelTheme.fillRect(pixelRect(2.0, 5.5, 1.0, 1.0, in: rect, s: s), color: PixelTheme.bg)
        PixelTheme.fillRect(pixelRect(5.0, 5.5, 1.0, 1.0, in: rect, s: s), color: PixelTheme.bg)
        PixelTheme.fillRect(pixelRect(1.8, 6.5, 0.5, 0.4, in: rect, s: s), color: PixelTheme.bg)
        PixelTheme.fillRect(pixelRect(5.7, 6.5, 0.5, 0.4, in: rect, s: s), color: PixelTheme.bg)
        // 嘴(笑嘴)—比 idle 宽
        PixelTheme.fillRect(pixelRect(2.5, 4.5, 3.0, 0.5, in: rect, s: s), color: PixelTheme.bg)
        // 身体 + 尾巴(尾上翘)
        PixelTheme.fillRect(pixelRect(1.5, 1.5, 5.0, 3.0, in: rect, s: s), color: color)
        PixelTheme.fillRect(pixelRect(7.5, 2.5, 1.0, 0.6, in: rect, s: s), color: color)
        PixelTheme.fillRect(pixelRect(8.0, 3.5, 0.8, 0.5, in: rect, s: s), color: color)

        // 头顶星粒子(按 frame 数显示 0/1/2/3 颗,位置分散)
        // frame 0 → 0 颗,frame 1 → 1 颗,frame 2 → 2 颗,frame 3 → 3 颗
        if frame >= 1 {
            // 中间偏左(固定位置,逐帧亮起)
            PixelTheme.fillRect(pixelRect(2.0, 8.5, 0.5, 0.5, in: rect, s: s), color: color)
        }
        if frame >= 2 {
            // 右侧
            PixelTheme.fillRect(pixelRect(5.5, 8.5, 0.5, 0.5, in: rect, s: s), color: color)
        }
        if frame >= 3 {
            // 中央最高
            PixelTheme.fillRect(pixelRect(3.7, 9.0, 0.5, 0.5, in: rect, s: s), color: color)
        }
    }

    // MARK: - completed: workbuddy (嗥叫张嘴 + 雪花)

    /// Completed 动画:下颌开合(frame 0/2 闭嘴,frame 1/3 张嘴),雪花
    /// 2 片按帧出现在画面两侧(frame 2/3 出现)。
    /// 4 帧循环。
    private static func drawWolfCompleted(in rect: NSRect, color: NSColor, frame: Int) {
        let s = min(rect.width, rect.height) / 10
        guard s > 1 else { return }

        // 竖耳
        PixelTheme.fillRect(pixelRect(1.0, 7.0, 1.0, 1.5, in: rect, s: s), color: color)
        PixelTheme.fillRect(pixelRect(6.0, 7.0, 1.0, 1.5, in: rect, s: s), color: color)
        // 头 + V 字下沿
        PixelTheme.fillRect(pixelRect(1.0, 4.5, 6.0, 3.0, in: rect, s: s), color: color)
        PixelTheme.fillRect(pixelRect(2.0, 7.0, 1.0, 0.5, in: rect, s: s), color: color)
        PixelTheme.fillRect(pixelRect(5.0, 7.0, 1.0, 0.5, in: rect, s: s), color: color)
        // V 字眼(眯眼,眯成线)
        PixelTheme.fillRect(pixelRect(2.0, 5.8, 1.0, 0.3, in: rect, s: s), color: PixelTheme.bg)
        PixelTheme.fillRect(pixelRect(5.0, 5.8, 1.0, 0.3, in: rect, s: s), color: PixelTheme.bg)
        // 张嘴(嗥叫):下颌开合,frame 偶数=闭嘴,奇数=张嘴
        if frame % 2 == 1 {
            // 张嘴:头部下方开一个矩形口
            PixelTheme.fillRect(pixelRect(3.0, 4.7, 2.0, 1.0, in: rect, s: s), color: PixelTheme.bg)
            // 上齿(1 像素白条)
            PixelTheme.fillRect(pixelRect(3.0, 5.2, 2.0, 0.3, in: rect, s: s), color: color)
        } else {
            // 闭嘴:嘴线
            PixelTheme.fillRect(pixelRect(3.0, 5.0, 2.0, 0.4, in: rect, s: s), color: PixelTheme.bg)
        }
        // 身体
        PixelTheme.fillRect(pixelRect(1.5, 1.5, 5.0, 3.0, in: rect, s: s), color: color)

        // 雪花(头两侧):frame 2/3 出现(frame 0/1 不画)
        if frame >= 2 {
            // 左雪花(两点)
            PixelTheme.fillRect(pixelRect(0.0, 6.0, 0.4, 0.4, in: rect, s: s), color: color)
            PixelTheme.fillRect(pixelRect(-0.4, 5.0, 0.3, 0.3, in: rect, s: s), color: color)
        }
        if frame >= 3 {
            // 右雪花
            PixelTheme.fillRect(pixelRect(8.0, 6.0, 0.4, 0.4, in: rect, s: s), color: color)
            PixelTheme.fillRect(pixelRect(8.5, 5.0, 0.3, 0.3, in: rect, s: s), color: color)
        }
    }

    // MARK: - completed: qwenwork (振翅高飞 + 羽冠伸长)

    /// Completed 动画:翅膀按帧位置越高(frame 0 在身侧,frame 3 高过头部)+
    /// 羽冠逐帧伸长(frame 0 一节,frame 3 四节)— 表示"振翅高飞"。
    /// 4 帧循环。
    private static func drawPhoenixCompleted(in rect: NSRect, color: NSColor, frame: Int) {
        let s = min(rect.width, rect.height) / 10
        guard s > 1 else { return }

        // 羽冠按 frame 伸长(从 1 节到 4 节,逐帧加)
        // frame 0: 1 节;frame 1: 2 节;frame 2: 3 节;frame 3: 4 节
        let crestHeight = 1.0 + Double(frame) * 0.5  // 1.0 / 1.5 / 2.0 / 2.5
        // 羽冠位置:居中,向上方延伸(羽冠顶端更高)
        let crestTopY = 8.0 - (crestHeight - 1.0)
        PixelTheme.fillRect(pixelRect(3.7, crestTopY, 0.6, crestHeight, in: rect, s: s), color: color)
        // 两侧小羽(随冠伸长)
        if frame >= 1 {
            PixelTheme.fillRect(pixelRect(3.0, 7.0, 0.4, 0.8, in: rect, s: s), color: color)
        }
        if frame >= 2 {
            PixelTheme.fillRect(pixelRect(4.6, 7.0, 0.4, 0.8, in: rect, s: s), color: color)
        }
        if frame >= 3 {
            PixelTheme.fillRect(pixelRect(2.5, 6.5, 0.3, 0.6, in: rect, s: s), color: color)
            PixelTheme.fillRect(pixelRect(5.2, 6.5, 0.3, 0.6, in: rect, s: s), color: color)
        }

        // 头
        PixelTheme.fillRect(pixelRect(1.5, 5.0, 5.0, 2.5, in: rect, s: s), color: color)
        // 眼
        PixelTheme.fillRect(pixelRect(2.5, 5.7, 0.8, 0.8, in: rect, s: s), color: PixelTheme.bg)
        PixelTheme.fillRect(pixelRect(4.7, 5.7, 0.8, 0.8, in: rect, s: s), color: PixelTheme.bg)
        // 喙
        PixelTheme.fillRect(pixelRect(3.5, 4.5, 1.0, 0.5, in: rect, s: s), color: PixelTheme.bg)

        // 身体(按 frame 上移,frame 0 在基准位,frame 3 上浮 0.3px)
        let bodyYOffset = Double(frame) * 0.3
        PixelTheme.fillRect(pixelRect(2.0, 1.5 + bodyYOffset, 4.0, 3.0, in: rect, s: s), color: color)

        // 翅膀:按 frame 位置越高(振翅上扬)
        // frame 0: 身侧(低位);frame 3: 头顶(高位)
        let wingRise = Double(frame) * 1.0  // 0/1/2/3 像素上升
        PixelTheme.fillRect(pixelRect(-0.3, 3.0 + wingRise, 1.5, 1.5, in: rect, s: s), color: color)
        PixelTheme.fillRect(pixelRect(6.8, 3.0 + wingRise, 1.5, 1.5, in: rect, s: s), color: color)
        // 翅尖额外小羽毛(frame 2/3 出现)
        if frame >= 2 {
            PixelTheme.fillRect(pixelRect(-0.5, 4.5 + wingRise, 0.6, 0.6, in: rect, s: s), color: color)
            PixelTheme.fillRect(pixelRect(7.9, 4.5 + wingRise, 0.6, 0.6, in: rect, s: s), color: color)
        }
    }

    // MARK: - completed: chatgpt (独角喷星)

    /// Completed 动画:独角顶部 3 颗小星按帧依次向上飞出(逐帧消失+新星
    /// 出现)— 表达"独角喷星"。独角本身亮度也按帧调制闪烁。
    /// 4 帧循环。
    private static func drawUnicornCompleted(in rect: NSRect, color: NSColor, frame: Int) {
        let s = min(rect.width, rect.height) / 10
        guard s > 1 else { return }

        // 喷星(3 颗,按 frame 出现在不同高度,模拟"喷出"序列)
        // frame 0: 最矮的星 + 中间的星 + 最高的星(三颗同时)
        // frame 1: 中间 + 高(矮消失,模拟飞出)
        // frame 2: 高(中间也消失)
        // frame 3: 都不画(空白帧,等待重置)
        switch frame {
        case 0:
            // 矮星(刚喷出,在独角根部上一点)
            PixelTheme.fillRect(pixelRect(3.7, 8.2, 0.4, 0.4, in: rect, s: s), color: color)
            fallthrough
        case 1:
            // 中星
            PixelTheme.fillRect(pixelRect(3.8, 8.7, 0.4, 0.4, in: rect, s: s), color: color)
            fallthrough
        case 2:
            // 高星(飞得最远)
            PixelTheme.fillRect(pixelRect(3.9, 9.2, 0.4, 0.4, in: rect, s: s), color: color)
        default:
            break
        }

        // 独角本身亮度按帧调制(frame 0/2 亮,frame 1/3 暗,模拟闪烁)
        let hornBrightness: CGFloat = (frame % 2 == 0) ? 1.0 : 0.6
        PixelTheme.fillRect(pixelRect(3.7, 7.0, 0.6, 1.0, in: rect, s: s),
                            color: color.withAlphaComponent(hornBrightness))
        // 头
        PixelTheme.fillRect(pixelRect(1.5, 4.5, 5.0, 2.5, in: rect, s: s), color: color)
        // 眼(眯眼线,与 wolf 类似)
        PixelTheme.fillRect(pixelRect(2.5, 5.8, 0.8, 0.3, in: rect, s: s), color: PixelTheme.bg)
        PixelTheme.fillRect(pixelRect(4.7, 5.8, 0.8, 0.3, in: rect, s: s), color: PixelTheme.bg)
        // 鼻
        PixelTheme.fillRect(pixelRect(3.7, 4.5, 0.6, 0.4, in: rect, s: s), color: PixelTheme.bg)
        // 圆环身(静止,与 idle 相同)
        PixelTheme.fillRect(pixelRect(2.0, 2.5, 4.0, 2.0, in: rect, s: s), color: color)
        PixelTheme.fillRect(pixelRect(2.5, 1.5, 3.0, 1.0, in: rect, s: s), color: color)
        PixelTheme.fillRect(pixelRect(3.0, 0.8, 2.0, 0.7, in: rect, s: s), color: color)
    }
}