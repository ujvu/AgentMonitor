import Foundation

/// 管理多个 active `IslandScene` 的展示选择与轮询。
///
/// FloatingIsland 不再自己维护 scene index 或轮询 timer —— 它只问
/// RotationManager「当前应该展示哪个场景」。
///
/// ### 规则（产品层定死，UI 不重复决策）
/// 1. `needsAttention` 优先且独占（不轮换，一直展示直到解决）。
/// 2. `working` 次之；多个 working 每 2 秒轮换。
/// 3. `completed`（celebration）短暂展示（3 秒后由 UI 侧 autoCollapse 收缩）。
/// 4. `idle`（dormant）不生成场景，不参与选择。
final class IslandRotationManager {

    // MARK: - 状态

    /// 当前待选场景数组（由 PresentationEngine 生成，RotationManager 只消费）。
    private var scenes: [IslandScene] = []
    /// 轮换下标（仅在多个 working 时推进）。
    private var activeIndex = 0
    /// 是否正在轮换（递归 asyncAfter 链）。
    private var rotating = false
    /// 完整一轮还需执行的 tick 次数;归零后展示完最后一个 agent,
    /// 再过一轮间隔通知结束。
    private var remainingRotationTicks = 0
    /// 每次轮换间隔（秒）。
    private let rotationInterval: TimeInterval = 2.0

    // MARK: - 场景注入

    /// 更新场景数组并重置轮换状态。每次状态事件后调用。
    func updateScenes(_ newScenes: [IslandScene]) {
        // 全量替换；下标重置，避免残留旧索引越界。
        scenes = newScenes
        activeIndex = 0
    }

    // MARK: - 选择

    /// 当前应展示的场景。nil = 无任何可展示场景（UI 应进入 dormant）。
    func currentScene() -> IslandScene? {
        guard !scenes.isEmpty else { return nil }
        // 规则1:needsAttention 独占优先。
        if let attention = scenes.first(where: { $0.mode == .attention }) {
            return attention
        }
        // 规则2:多个 working 轮换；单 working 固定。
        let working = scenes.filter { $0.mode == .active }
        if !working.isEmpty {
            let index = min(activeIndex, working.count - 1)
            return working[index]
        }
        // 规则3:celebration 短暂展示。
        return scenes.first
    }

    /// 推进轮换下标，返回下一个应展示的场景（多 working 场景）。
    /// 由调用方在轮换 timer 触发时调用。
    func nextScene() -> IslandScene? {
        let working = scenes.filter { $0.mode == .active }
        guard working.count > 1 else {
            // 不足两个 working → 无需轮换，返回当前。
            return currentScene()
        }
        activeIndex = (activeIndex + 1) % working.count
        return working[activeIndex]
    }

    // MARK: - 轮询控制（递归 asyncAfter，避开 RunLoop timer 不可靠的问题）

    /// 需要轮换吗？（多个 working 且无 attention 独占）
    var shouldRotate: Bool {
        guard !scenes.isEmpty else { return false }
        let hasAttention = scenes.contains { $0.mode == .attention }
        let workingCount = scenes.filter { $0.mode == .active }.count
        return !hasAttention && workingCount > 1
    }

    /// 启动 2 秒轮换。幂等。
    ///
    /// 完整展示一轮后自动结束:第一个 working 由 `currentScene()` 先行显示,
    /// 之后每个 tick 换下一个,当全部 working 都展示过一遍(共 workingCount-1
    /// 次 tick)后,再等一个 rotationInterval 调用 `tick(nil)` 通知调用方
    /// "轮换完成,可以收起岛"。调用方收到 nil 后应收起悬浮岛——多 agent
    /// 同时工作时,岛只展示一轮(每个 agent 各 2s)即退出,不常驻。
    func startRotation(tick: @escaping (IslandScene?) -> Void) {
        guard shouldRotate, !rotating else { return }
        rotating = true
        let workingCount = scenes.filter { $0.mode == .active }.count
        // 第一个已由 currentScene() 显示;每 tick 展示下一个。
        remainingRotationTicks = max(0, workingCount - 1)
        scheduleNext(tick: tick)
    }

    /// 停止轮换。下一次 asyncAfter 触发时 sees rotating=false 直接退出。
    func stopRotation() {
        rotating = false
        remainingRotationTicks = 0
    }

    private func scheduleNext(tick: @escaping (IslandScene?) -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + rotationInterval) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.rotating else { return }
                tick(self.nextScene())
                self.remainingRotationTicks -= 1
                if self.remainingRotationTicks <= 0 {
                    // 最后一个 working 已展示;再等一个 interval(让它完整
                    // 显示 2 秒)后通知结束 → 调用方收起岛。
                    DispatchQueue.global().asyncAfter(deadline: .now() + self.rotationInterval) { [weak self] in
                        DispatchQueue.main.async {
                            guard let self = self, self.rotating else { return }
                            self.rotating = false
                            tick(nil)
                        }
                    }
                    return
                }
                self.scheduleNext(tick: tick)
            }
        }
    }
}
