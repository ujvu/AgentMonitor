import Cocoa
import CoreVideo

// MARK: - Island Phase（v11 形变生命周期）

/// Dynamic Island 形变的四个阶段。
///
/// - dormant:    收起终态（idle 顶部细条，视觉近乎隐形）。
/// - awakening:  唤醒展开中（hidden → expanded / attention）。
/// - active:     展开稳定态（对应 expanded / attention 终态）。
/// - collapsing: 收起回 dormant 中（expanded / attention → hidden）。
/// - contentFadeIn:  内容淡入阶段（几何已稳定,只插值 contentAlpha 0→1）。
///                   用于 show() 序列末段与 IslandSceneTransition 交叉淡入。
/// - contentFadeOut: 内容淡出阶段（几何尚稳,只插值 contentAlpha 1→0）。
///                   用于 hide() 序列首段与 IslandSceneTransition 交叉淡出。
enum IslandPhase: Equatable {
    case dormant
    case awakening
    case active
    case collapsing
    case contentFadeIn
    case contentFadeOut
}

// MARK: - Morph State（逐帧渲染态）

/// 引擎每一帧算出的视觉几何，交给 `FloatingIsland` 渲染。
///
/// 引擎只算「几何 + 视觉参数」，不碰任何绘制逻辑——绘制仍在
/// `FloatingIsland`。所有形变维度（尺寸、圆角、阴影、模糊、内容透明度）
/// 走同一条时间线插值，因此严格同步，不会出现「frame 在动、圆角瞬跳」的割裂。
struct IslandMorphState {
    /// 目标窗口尺寸。
    var size: NSSize
    /// 圆角半径。Dynamic Island 语义下 = min(width, height) / 2，
    /// 保证窄时是胶囊、展开时是大圆角矩形，形变全程自然过渡。
    var cornerRadius: CGFloat
    /// 阴影不透明度（默认 0：保持贴顶无阴影决策；> 0 时渲染层才画阴影）。
    var shadowOpacity: CGFloat
    /// 背景模糊强度（预留接口：需 NSVisualEffectView 支持，当前不渲染）。
    var blurOpacity: CGFloat
    /// 内容（文字/头像/能量条）的透明度。展开末段淡入、收起初段淡出，
    /// 让内容“生长”出来而不是瞬间出现。
    var contentAlpha: CGFloat

    static let hidden = IslandMorphState(
        size: NSSize(width: 100, height: 4),
        cornerRadius: 2,
        shadowOpacity: 0,
        blurOpacity: 0,
        contentAlpha: 0
    )
}

// MARK: - Morph Target（目标态）

/// 一次形变的目标几何 + 视觉参数。
struct IslandMorphTarget {
    let size: NSSize
    let cornerRadius: CGFloat
    let shadowOpacity: CGFloat
    let blurOpacity: CGFloat
    let contentAlpha: CGFloat

    init(size: NSSize,
         cornerRadius: CGFloat,
         shadowOpacity: CGFloat = 0,
         blurOpacity: CGFloat = 0,
         contentAlpha: CGFloat = 1) {
        self.size = size
        self.cornerRadius = cornerRadius
        self.shadowOpacity = shadowOpacity
        self.blurOpacity = blurOpacity
        self.contentAlpha = contentAlpha
    }
}

// MARK: - Sequence step

/// 一次序列形变中的一段：从当前态插值到 target，持续 duration，标注 phase。
struct IslandMorphStep {
    let target: IslandMorphTarget
    let phase: IslandPhase
    let duration: TimeInterval
}

// MARK: - IslandAnimationEngine（v12 CVDisplayLink 形变引擎）

/// 负责驱动 `FloatingIsland` 的 Dynamic Island 形变动画。
///
/// ### 设计要点（v13：真实时钟 + 帧合并）
/// - v12 用 `CVDisplayLink` 驱动，在健康显示器上确实与 vsync 对齐；但在
///   显示器休眠 / 远程会话 / 高负载环境下，其回调会被严重饿死或延迟数分钟
///   （实测 0.6s 动画拖到 ~3s 甚至冻结），导致“收起很慢”——这正是用户
///   最初反馈的问题。v13 改为 **DispatchSourceTimer（120Hz）+ 每次触发时
///   读取当前 mach 时钟**：即使触发被系统调度延迟，进度也永远按真实墙钟
///   计算（t 直接跳到正确值），动画绝不会慢放，只会跳帧。
/// - **帧合并**：回调可能以高于主线程消费能力的频率触发（高负载下尤其），
///   每帧 main.async 入队会让动画按主队列排空速度慢放。只保留“最新一帧”，
///   主线程每轮至多应用一次，动画始终按真实时间推进。
/// - **回调线程只计算时间进度与数值插值（纯数学，不碰任何 AppKit）**；
///   所有窗口/视图更新（onApply / onComplete）一律 `DispatchQueue.main.async`。
/// - `NSLock` 保护 `sequenceId` / `current` / 活动序列：主线程
///   `morph`/`morphSequence`/`cancel` 写入，回调线程读取。
/// - **取消机制**：每次 `morph`/`morphSequence`/`cancel` 自增 `sequenceId`，
///   已入队的旧帧在主队列应用前再次校验 id，不匹配即丢弃并记日志——
///   新的 show/hide 到来时旧序列立即作废，避免展开与收起同时执行。
/// - 空闲（无活动序列）时自动停表，省电。
final class IslandAnimationEngine {

    /// 活动序列（回调线程读取、主线程写入，由 `lock` 保护）。
    private struct ActiveSequence {
        var steps: [IslandMorphStep]
        var index: Int
        /// 当前段的起始时刻（`ProcessInfo.systemUptime`，秒）。
        var segmentStart: Double
    }

    private let lock = NSLock()
    /// 取消令牌：每次新动画自增；已入队的旧帧在应用前校验，不匹配即丢弃。
    private var sequenceId: UInt64 = 0
    /// 当前渲染态：下次形变的起点，永远是真实当前态（避免跳变）。
    private var current: IslandMorphState = .hidden
    /// 活动序列；nil = 无动画（定时器空闲停止）。
    private var active: ActiveSequence?
    /// 120Hz 驱动定时器（替代 v12 的 CVDisplayLink，规避其在休眠/远程/
    /// 高负载环境下回调被饿死导致的“动画慢放”）。
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "cn.qwenwork.AgentMonitor.Animation",
                                           qos: .userInteractive)

    // MARK: 帧合并（coalescing）
    //
    // 某些环境（显示器休眠时的 CVDisplayLink 回退模式）回调会以远高于
    // 主线程消费能力的频率投递（实测 ~2500fps）。若每帧都 main.async
    // 入队，主队列堆积 → 动画按排空速度“慢放”（实测 0.6s 动画拖到 ~3s）。
    // 这里只保留“最新一帧”，主线程每轮至多应用一次：动画始终按真实时间
    // 推进，主线程负载从 2500 帧/秒降到 ~60 帧/秒。健康显示器（60Hz）下
    // 每回调一帧，合并是零开销的。
    /// 最新待应用帧（回调线程写、主线程读，由 `lock` 保护）。
    private var pendingApply: (id: UInt64, state: IslandMorphState)?
    /// 待补发的段完成回调（一段的终帧可能被合并吞掉，须补发）。
    private var pendingPhases: [IslandPhase] = []
    /// 主队列是否已有一轮 flush 在途（保证最多一个 pending）。
    private var applyScheduled = false

    /// 每帧回调：把插值后的态应用到渲染层（主队列调用）。
    var onApply: ((IslandMorphState) -> Void)?
    /// 序列中每段完成回调（主队列调用），携带该段的 phase。
    /// 整个序列完成时 phase 为最后一段的 phase。
    var onComplete: ((IslandPhase) -> Void)?

    deinit {
        stopTimer()
    }

    /// 把引擎当前态同步为窗口真实几何（启动 / 重置时用）。
    func syncCurrent(_ state: IslandMorphState) {
        lock.lock()
        current = state
        lock.unlock()
    }

    /// 启动一次单段形变：从当前态插值到 `target`。
    ///
    /// 若上一次形变尚未结束，直接从当前插值态接上新目标，避免回弹跳变。
    /// 同时自增 sequenceId，使任何正在跑的旧序列作废。
    func morph(to target: IslandMorphTarget,
               phase: IslandPhase,
               duration: TimeInterval = 0.3) {
        morphSequence([IslandMorphStep(target: target, phase: phase, duration: duration)])
    }

    /// 启动一个多段序列形变：按顺序串行执行每一步。
    ///
    /// 中途若被新动画取消（sequenceId 变化），已入队的旧帧被丢弃、后续段
    /// 不再执行。整个序列完成后回调 `onComplete`（携带最后一段的 phase）。
    func morphSequence(_ steps: [IslandMorphStep]) {
        guard !steps.isEmpty else { return }

        lock.lock()
        sequenceId &+= 1
        let myId = sequenceId
        // 时钟：systemUptime（单调、秒）。不能用 mach_absolute_time 的裸
        // ticks——M1 timebase 为 125/3 ns/tick，直接当纳秒用会让动画慢
        // ~41.7 倍（v12“收起慢”的根因）。
        active = ActiveSequence(steps: steps, index: 0,
                                segmentStart: ProcessInfo.processInfo.systemUptime)
        lock.unlock()

        Logger.shared.logInfo("IslandAnimationEngine start sequence #\(myId) steps=\(steps.count)")
        ensureTimer()
    }

    /// 立即取消所有进行中的动画（不触发 onComplete）。
    func cancel() {
        lock.lock()
        sequenceId &+= 1
        active = nil
        lock.unlock()
        stopTimer()
        Logger.shared.logInfo("IslandAnimationEngine cancel()")
    }

    // MARK: - Timer driver

    /// 惰性创建 120Hz 驱动定时器。回调线程**只计算时间进度与数值插值**；
    /// 所有 AppKit 更新在 main.async。
    ///
    /// 每次触发读取当前 mach 时间：即使定时器触发被系统调度延迟，
    /// elapsed 也按真实墙钟计算——动画只会跳帧、绝不会慢放。
    private func ensureTimer() {
        lock.lock()
        if let t = timer, !t.isCancelled {
            lock.unlock()
            return
        }
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now(), repeating: 1.0 / 120.0, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            self?.tick(now: ProcessInfo.processInfo.systemUptime)
        }
        timer = t
        lock.unlock()
        t.resume()
    }

    /// 空闲停表。可从定时器回调线程调用（DispatchSourceTimer 无
    /// CVDisplayLink 那种“Stop 等待回调返回”的死锁风险）。
    private func stopTimer() {
        lock.lock()
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
    }

    // MARK: - Frame tick（定时器回调线程）

    /// 每帧（120Hz）：计算时间进度 → 插值状态 → 主队列应用。
    ///
    /// 在定时器回调线程执行，**不碰任何 AppKit 对象**——
    /// `NSLock` 保护的只有纯数值状态（sequenceId / current / active）。
    /// `now` 为触发时刻的 systemUptime（秒）；即使触发被延迟，进度也按
    /// 真实墙钟算。
    private func tick(now: Double) {
        lock.lock()
        guard let seq = active, !seq.steps.isEmpty else {
            lock.unlock()
            return
        }
        // 首帧保护：now 可能略早于启动时刻，直接跳过。
        if now < seq.segmentStart {
            lock.unlock()
            return
        }
        let myId = sequenceId
        // 新序列的第一帧：丢弃上一序列遗留的段完成回调（旧 collapse 的
        // .collapsing 补发不应落到新展开序列上）。
        if pendingApply?.id != myId {
            pendingPhases.removeAll()
        }
        let step = seq.steps[seq.index]
        let d = max(step.duration, 0.01)
        let elapsed = now - seq.segmentStart
        var t = elapsed / d
        if t > 1.0 { t = 1.0 }
        let e = Self.easeInOut(t)
        let from = current
        let state = IslandMorphState(
            size: NSSize(width: Self.lerp(from.size.width, step.target.size.width, e),
                         height: Self.lerp(from.size.height, step.target.size.height, e)),
            cornerRadius: Self.lerp(from.cornerRadius, step.target.cornerRadius, e),
            shadowOpacity: Self.lerp(from.shadowOpacity, step.target.shadowOpacity, e),
            blurOpacity: Self.lerp(from.blurOpacity, step.target.blurOpacity, e),
            contentAlpha: Self.lerp(from.contentAlpha, step.target.contentAlpha, e)
        )
        current = state

        if t >= 1.0 {
            // 段完成：补发其 phase（终帧可能被合并，不能依赖逐帧投递）。
            pendingPhases.append(step.phase)
            if seq.index + 1 < seq.steps.count {
                // 下一段从本段终态起步（current 已是该段 target）。
                active?.index += 1
                active?.segmentStart = now
            } else {
                active = nil
            }
        }

        // 帧合并：只保留最新一帧，主队列每轮至多 flush 一次。
        pendingApply = (myId, state)
        let needSchedule = !applyScheduled
        if needSchedule { applyScheduled = true }
        lock.unlock()

        if needSchedule {
            DispatchQueue.main.async { [weak self] in
                self?.flushPendingApply()
            }
        }

        if active == nil {
            stopTimer()
        }
    }

    /// 主线程：应用最新一帧 + 按序补发段完成回调。
    ///
    /// 应用前校验 id——若主线程已启动新动画，本帧作废（取消机制的
    /// 最后一环），同时丢弃其段完成回调（如被 show() 打断的 collapse
    /// 不应再触发 orderOut）。
    private func flushPendingApply() {
        lock.lock()
        applyScheduled = false
        guard let pending = pendingApply else {
            lock.unlock()
            return
        }
        pendingApply = nil
        let stillCurrent = sequenceId == pending.id
        let state = pending.state
        let phases = pendingPhases
        pendingPhases.removeAll()
        lock.unlock()

        guard stillCurrent else {
            Logger.shared.logInfo("IslandAnimationEngine dropped stale frame #\(pending.id)")
            return
        }
        onApply?(state)
        for phase in phases {
            onComplete?(phase)
        }
    }

    // MARK: - Easing & lerp

    /// 与原有 `CAMediaTimingFunction(name: .easeInEaseOut)` 对齐的缓动曲线。
    private static func easeInOut(_ t: Double) -> Double {
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        return a + (b - a) * CGFloat(t)
    }
}
