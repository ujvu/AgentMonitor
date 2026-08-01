import Foundation

/// OCR 时序证据聚合器(Phase 7.1):集中持有"活动窗口 + working lease"状态,
/// 由 `AppWatcher.handleOCRResult` 在 OCR 完成时单次驱动,而不是每次 poll
/// 反复刷新。这样:
///   - 同一 OCR 帧只产生一次 lease create/renew(不会在 poll 里被同一
///     `ocrResult` 反复续期)
///   - `currentOCREvidence()` 退化为纯读取,无副作用
///   - `reset()` 一处清空所有瞬态,App 未运行 / stop 不再继承旧 OCR 结果
///
/// 时间点一律用调用方传入的 `now`,内部不 new Date(),保证日志与判定一致。
struct OCRTemporalAggregator {

    // MARK: - Sample window

    private struct Sample {
        let timestamp: Date
        let score: Int
        let fingerprint: UInt64
    }

    private var recentActivity: [Sample] = []

    // MARK: - Lease

    private(set) var workingLease: Bool = false
    private(set) var lastActivityTime: Date?

    // MARK: - Tunables

    /// lease 时长与活动窗口上限(秒)。lease 创建后,在 `windowSeconds` 内无
    /// 续期信号即视为到期 → 翻回非 working,交由现有 downgrade 3 次确认。
    let windowSeconds: TimeInterval = 6
    /// 累加活动分的时间窗(秒)。活动分只统计 `now` 之前 `renewalWindow` 内
    /// 的样本,超过即不计入"工具活动仍活跃"判定。
    let renewalWindow: TimeInterval = 4
    /// 活动分累加阈值;`renewalWindow` 内总分 ≥ 此值即视为持续工具活动。
    let renewalThreshold: Int = 3

    // MARK: - Frame ingestion

    /// 记录一帧 OCR 活动信号。
    ///
    /// Novelty gate:仅当本帧指纹与上一帧不同(文本移动过)时才计入分数。
    /// 这样静态历史(翻看含工具说明的旧回复)永远无法累积出 lease,而
    /// 实时流式输出(任务执行)能累积。novelty gate 不影响 lease 续期,
    /// 续期由 `AppWatcher.handleOCRResult` 按状态/指纹/活动分决定。
    ///
    /// 仅追加样本 + 修剪超 `windowSeconds` 的条目;不触碰 lease。
    mutating func recordFrame(score: Int, fingerprint: UInt64, now: Date) {
        let previous = recentActivity.last?.fingerprint
        let novel = previous != nil && previous != fingerprint
        recentActivity.append(Sample(timestamp: now,
                                     score: novel ? score : 0,
                                     fingerprint: fingerprint))
        let cutoff = windowSeconds
        recentActivity.removeAll { now.timeIntervalSince($0.timestamp) > cutoff }
    }

    // MARK: - Queries (pure)

    /// `renewalWindow` 内所有样本的活动分总和。
    func activityWindowScore(now: Date) -> Int {
        recentActivity
            .filter { now.timeIntervalSince($0.timestamp) <= renewalWindow }
            .reduce(0) { $0 + $1.score }
    }

    /// 最近两个样本的指纹是否不同(文本是否在流动)。不足两样本时为 false。
    func fingerprintChanged() -> Bool {
        guard recentActivity.count >= 2 else { return false }
        let n = recentActivity.count
        return recentActivity[n - 1].fingerprint != recentActivity[n - 2].fingerprint
    }

    /// lease 是否仍在 `windowSeconds` 窗口内(最近一次创建/续期距今未超期)。
    func leaseAlive(now: Date) -> Bool {
        guard let last = lastActivityTime else { return false }
        return now.timeIntervalSince(last) <= windowSeconds
    }

    // MARK: - Lease mutations

    /// 创建 lease:首次进入 working。记录锚点时间。
    mutating func createLease(at date: Date) {
        workingLease = true
        lastActivityTime = date
    }

    /// 续期 lease:刷新锚点时间。语义上要求已有 lease,但即便误用也无害
    /// (把 false 翻成 true + 重置锚点),因此不做断言。
    mutating func renewLease(at date: Date) {
        workingLease = true
        lastActivityTime = date
    }

    /// 清除 lease(completed / needsAttention / 重置):workingLease=false,
    /// 且把锚点时间置 nil,彻底脱离 working 态。
    mutating func clearLease() {
        workingLease = false
        lastActivityTime = nil
    }

    /// 若 lease 已超期(最近锚点距今 > `windowSeconds`)则把 workingLease
    /// 翻回 false。与 `clearLease` 不同:这里 **不** 置空 lastActivityTime,
    /// 保留最后一次活跃时间便于诊断/日志区分"自然到期"与"显式清除"。
    /// 返回本次调用是否真的触发了到期翻转(供日志使用)。
    @discardableResult
    mutating func expireIfDue(now: Date) -> Bool {
        guard workingLease, !leaseAlive(now: now) else { return false }
        workingLease = false
        return true
    }

    // MARK: - Reset

    /// 清空全部瞬态(活动窗口 + lease)。App 未运行 / watcher.stop 时调用。
    mutating func reset() {
        recentActivity.removeAll()
        workingLease = false
        lastActivityTime = nil
    }
}
