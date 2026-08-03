import Foundation
import ApplicationServices
import AppKit

/// Delegate protocol for per-app state and signal callbacks.
///
/// `stateDidChangeTo` now carries a `StateSnapshot` (status + provenance) so
/// consumers can show source/confidence if they want, while still doing
/// status-based change detection via Equatable (which compares status only).
protocol AppWatcherDelegate: AnyObject {
    func appWatcher(_ watcher: AppWatcher, didDetectSignal signal: AttentionSignal)
    func appWatcher(_ watcher: AppWatcher, stateDidChangeTo snapshot: StateSnapshot)
}

/// Watches a single app by polling its Accessibility tree at intervals, fusing
/// AX evidence with optional Vision-OCR evidence, and confirming status
/// transitions through a pending window to avoid flicker.
///
/// State model:
///   Evidence (AX/OCR) → FusionEngine → {stable | transitionNeeded}
///                                                │
///                                  PendingManager │ (confirm before commit)
///                                                ▼
///                                  committed StateSnapshot → delegate + events
///
/// Dedup: the same signal type + snippet within `dedupInterval` is skipped.
final class AppWatcher {

    let definition: AppDefinition
    weak var delegate: AppWatcherDelegate?

    // MARK: - Timing

    /// Interval between accessibility-tree polls.
    let pollInterval: TimeInterval = 2.0
    /// OCR interval while the app window is frontmost. Lowered from 5s to 3s
    /// so short-lived working indicators (spinner text "正在执行命令" visible
    /// for ~2s) are reliably caught at least once before they disappear.
    let ocrIntervalForeground: TimeInterval = 3.0
    /// OCR interval while the app is in the background (reduced cost).
    let ocrIntervalBackground: TimeInterval = 12.0
    /// Window during which duplicate signals (same type + snippet) are suppressed.
    let dedupInterval: TimeInterval = 15.0
    /// Consecutive confirming polls required before an UPGRADE transition
    /// (e.g. idle→working) is committed. Upgrades should react fast — a single
    /// confirming poll is enough because starting work is unambiguous.
    let confirmThresholdUpgrade = 1
    /// Consecutive confirming polls required before a DOWNGRADE transition
    /// (e.g. working→idle/completed) is committed. Downgrades need more caution:
    /// at a 2s poll, 3 ≈ 6 seconds of continuous agreement, which prevents a
    /// single dropped frame or brief AX/OCR dropout from falsely ending a task.
    let confirmThresholdDowngrade = 3

    // MARK: - Cognition state

    /// The committed cognitive snapshot (status + provenance). Mutated only on
    /// the poll queue.
    private(set) var currentSnapshot: StateSnapshot = .initialIdle
    /// Previous status used for working→idle transition detection (mirrors the
    /// old `wasWorking` semantics, now on pure status).
    private var wasWorking: Bool = false
    /// In-flight status transition awaiting confirmation.
    private var pending: PendingTransition?

    // MARK: - AX detector tracking state (caller-owned, threaded through SignalDetector)

    private var lastSendEnabled: Bool = true
    private var lastTimerText: String? = nil

    // MARK: - OCR state

    /// Latest OCR verdict, or nil if never run / stale.
    private var ocrResult: VisionDetector.OCRResult?
    /// When the latest OCR result was produced.
    private var lastOCRAt: Date?
    /// Guards against overlapping OCR runs.
    private var ocrInProgress: Bool = false
    private var ocrSkipLog: Int = 0

    // MARK: - OCR temporal aggregation (Phase 7.1)

    /// Activity window + working lease, driven solely by
    /// `handleOCRResult` on OCR completion. `currentOCREvidence` is a pure
    /// reader of this state (no per-poll mutation).
    private var temporal = OCRTemporalAggregator()
    /// Evidence computed once per OCR frame in `handleOCRResult`. Holds the
    /// explicit (working/completed/needsAttention) verdict; `nil` for plain
    /// unknown frames (then `currentOCREvidence` falls back to a lease-held
    /// working evidence while the lease is alive).
    private var cachedOCREvidence: Evidence?
    /// True after OCR has actually established a working state in the current
    /// app session. Once this is set, AX-idle alone is not allowed to end the
    /// round: Electron Worker surfaces often expose no live status through AX.
    private var hasSeenOCRWorking = false
    /// Number of independent OCR frames after the latest working frame that
    /// found no active/terminal marker. Polls must never increment this value;
    /// otherwise one stale frame is counted repeatedly as several confirmations.
    private var consecutiveOCRUnknownFrames = 0

    // MARK: - Signal dedup

    /// Last dedup key: (signal type, element snippet, timestamp).
    private var lastDedup: (type: SignalType, snippet: String, time: Date)?

    // MARK: - Timers

    private var pollTimer: DispatchSourceTimer?
    private var ocrTimer: DispatchSourceTimer?
    private var pollCount: Int = 0
    private let queue = DispatchQueue(label: "cn.qwenwork.AgentMonitor.AppWatcher",
                                      qos: .utility)

    // MARK: - Init

    init(definition: AppDefinition) {
        self.definition = definition
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in
            self?.poll()
        }
        t.resume()
        pollTimer = t

        // OCR fallback only for apps that opt in via ocrRule.
        if definition.rule.ocrRule != nil {
            startOCRTimer()
        }

        Logger.shared.logInfo("AppWatcher[\(definition.id)] started (poll=\(pollInterval)s\(definition.rule.ocrRule != nil ? ", ocr=on" : ""))")
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        ocrTimer?.cancel()
        ocrTimer = nil
        // Drop transient OCR/lease state so a later start() never inherits a
        // stale verdict (e.g. app was quit & reopened — the old OCR frame and
        // lease must not carry over).
        resetTransientDetectionState(reason: "stop")
        Logger.shared.logInfo("AppWatcher[\(definition.id)] stopped")
    }

    /// Clears all transient OCR/lease/pending state. Leaves `currentSnapshot`
    /// and `wasWorking` untouched (the last committed status persists until a
    /// new poll changes it). Called on `stop()` and when the app is found to
    /// be not running in `poll()`.
    private func resetTransientDetectionState(reason: String) {
        let observedAt = Date()
        ocrResult = nil
        lastOCRAt = nil
        ocrInProgress = false
        temporal.reset()
        pending = nil
        cachedOCREvidence = nil
        hasSeenOCRWorking = false
        consecutiveOCRUnknownFrames = 0
        Logger.shared.logInfo("AppWatcher[\(definition.id)] session reset reason=\(reason) observedAt=\(ISO8601DateFormatter().string(from: observedAt))")
    }

    // MARK: - OCR scheduling

    private func startOCRTimer() {
        guard ocrTimer == nil else { return }
        scheduleOCR(after: currentOCRInterval())
    }

    /// Reschedules the OCR timer at the right cadence. Cadence is driven
    /// by the app's `ocrRule.foregroundInterval` / `backgroundInterval`,
    /// switching based on whether the app is frontmost. Re-evaluated on each
    /// fire so a foreground/background flip takes effect within one tick.
    /// Must NOT hardcode `definition.id`; cadence is per-app via ocrRule.
    private func currentOCRInterval() -> TimeInterval {
        let rule = definition.rule.ocrRule
        let foreground = rule?.foregroundInterval ?? ocrIntervalForeground
        let background = rule?.backgroundInterval ?? ocrIntervalBackground
        return isAppFrontmost() ? foreground : background
    }

    /// True when the watched app is the active (frontmost) GUI app. Uses
    /// `NSRunningApplication.isActive` (the modern macOS 11+ replacement for
    /// the deprecated `activationPolicy` checks) — pure-bool, no side effects.
    private func isAppFrontmost() -> Bool {
        let apps = NSRunningApplication.runningApplications(
            withBundleIdentifier: definition.bundleId)
        return apps.first?.isActive ?? false
    }

    private func scheduleOCR(after interval: TimeInterval) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Re-evaluate cadence each tick so a foreground↔background flip
            // takes effect within one OCR interval.
            let next = self.currentOCRInterval()
            if abs(next - interval) > 0.001 {
                self.scheduleOCR(after: next)
                return
            }
            self.runOCR()
        }
        t.resume()
        ocrTimer?.cancel()
        ocrTimer = t
    }

    /// One OCR cycle. Skips if a previous run is still in flight or the window
    /// isn't visible. Updates `ocrResult`/`lastOCRAt` on the main queue.
    private func runOCR() {
        guard let rule = definition.rule.ocrRule else { return }
        guard !ocrInProgress else { return }

        // Only OCR when the app is running AND has a visible on-screen window.
        // We deliberately use CGWindowList (via findWindowId) rather than AX's
        // focusedWindow: AX focusedWindow returns nil for backgrounded Electron
        // apps and even for some frontmost Electron windows, which caused OCR to
        // be skipped permanently for WorkBuddy (so its working state was never
        // detected). findWindowId uses the same CGWindowList path the screenshot
        // capture uses, so it reliably finds on-screen windows regardless of AX.
        let appFound = AXUtilities.findApp(bundleId: definition.bundleId,
                                           processName: definition.processName) != nil
        let winFound = ScreenshotCapture.findWindowId(bundleId: definition.bundleId) != nil
        guard appFound, winFound else {
            if ocrSkipLog % 10 == 0 {
                Logger.shared.logWarning("runOCR SKIP [\(definition.id)] bundleId=\(definition.bundleId) findApp=\(appFound) findWindowId=\(winFound)")
            }
            ocrSkipLog += 1
            return
        }
        ocrSkipLog = 0
        Logger.shared.logInfo("runOCR FIRING [\(definition.id)]")
        ocrInProgress = true
        let bundleId = definition.bundleId
        VisionDetector.detect(bundleId: bundleId, rule: rule) { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                // OCR completed → drive the temporal aggregator ONCE here.
                // All lease create/renew/clear/expire and the cached evidence
                // are decided in handleOCRResult; currentOCREvidence() is a
                // pure reader and never mutates on poll.
                self.handleOCRResult(result: result, observedAt: Date())
            }
        }
    }

    // MARK: - Poll (AX → evidence → fusion → pending → commit)

    private func poll() {
        pollCount += 1

        // --- 1. AX detection (unchanged logic; produces an AgentStatus) ---
        var axStatus: AgentStatus = currentSnapshot.status
        var detectedSignal: AttentionSignal? = nil

        guard let app = AXUtilities.findApp(bundleId: definition.bundleId,
                                            processName: definition.processName) else {
            // App not running → idle, no crash. Also drop transient OCR/lease
            // state so a later reopen never inherits the pre-quit verdict.
            resetTransientDetectionState(reason: "app not running")
            commitIdleIfChanged(reason: "app not running")
            if pollCount % 5 == 0 {
                Logger.shared.logDebug("AppWatcher[\(definition.id)]: not running (poll #\(pollCount))")
            }
            return
        }

        // CPU guard: if the app has NO on-screen window (minimized/hidden/
        // fully backgrounded), skip the expensive AX tree traversal + signal
        // detection this cycle — keep the LAST committed status as-is. This
        // avoids forcing a backgrounded-but-still-working app to idle (its
        // window may be minimized while it keeps running a task), while still
        // cutting the dominant CPU cost (AX traversal of hidden Electron apps).
        //
        // IMPORTANT: we must NOT `return` here — cached OCR evidence (e.g. a
        // needsAttention verdict captured just before the window went
        // off-screen) must still flow into fusion, otherwise a pending
        // attention/working signal gets swallowed and the island never shows
        // it. So the guard only gates the AX path; OCR evidence is always
        // consumed below.
        let windowVisible = ScreenshotCapture.findWindowId(bundleId: definition.bundleId) != nil
        if windowVisible {
            detectedSignal = SignalDetector.detect(app: app,
                                                   definition: definition,
                                                   state: &axStatus,
                                                   lastSendEnabled: &lastSendEnabled,
                                                   lastTimerText: &lastTimerText)
        } else if pollCount % 10 == 0 {
            Logger.shared.logDebug("AppWatcher[\(definition.id)]: no on-screen window, skip AX traversal (poll #\(pollCount))")
        }

        // --- 2. Build evidence ---
        // AX evidence only when the window is visible; otherwise nil so fusion
        // falls back to (possibly cached) OCR evidence alone.
        let axEvidence: Evidence? = windowVisible
            ? Evidence(source: .ax,
                       conclusion: axStatus,
                       confidence: 1.0,
                       timestamp: Date(),
                       snippet: detectedSignal?.elementSnippet ?? "")
            : nil

        let ocrEvidence: Evidence? = currentOCREvidence()
        // DIAG: show OCR evidence entering fusion (every 10th poll to avoid spam)
        if pollCount % 10 == 0 {
            if let oe = ocrEvidence {
                Logger.shared.logInfo("AppWatcher[\(definition.id)]: OCR-EVIDENCE state=\(oe.conclusion.label) src=ocr conf=\(String(format:"%.2f",oe.confidence)) snippet=\"\(oe.snippet)\"")
            } else {
                Logger.shared.logDebug("AppWatcher[\(definition.id)]: OCR-EVIDENCE nil (no fresh/stale/unknown)")
            }
        }

        // --- 3. Fuse ---
        let fusion = FusionEngine.fuse(current: currentSnapshot.status,
                                       axEvidence: axEvidence,
                                       ocrEvidence: ocrEvidence)

        // --- 4. Apply fusion via pending confirmation ---
        switch fusion {
        case .stable(let snapshot):
            // No upgrade proposed. Any pending upgrade is now contradicted → drop it.
            if pending != nil {
                Logger.shared.logDebug("AppWatcher[\(definition.id)]: pending \(pending!.target.label) cancelled (stable \(snapshot.status.label))")
                pending = nil
            }
            commitSnapshot(snapshot, reason: reasonFor(axStatus, ocrEvidence))

        case .transitionNeeded(let target, let evidence):
            // OCR-backed Electron surfaces (especially ChatGPT Worker) often
            // report AX idle for the entire task. Never treat that permanent AX
            // idle as three independent completion confirmations. Wait until an
            // in-flight OCR pass finishes and two NEW OCR frames independently
            // report no working marker. Explicit completed/attention verdicts
            // still pass through immediately.
            if Self.shouldDeferOCRBackedWorkingExit(
                current: currentSnapshot.status,
                target: target,
                hasSeenOCRWorking: hasSeenOCRWorking,
                consecutiveOCRUnknownFrames: consecutiveOCRUnknownFrames,
                ocrInProgress: ocrInProgress
            ) {
                if pending != nil {
                    pending = nil
                }
                Logger.shared.logDebug(
                    "AppWatcher[\(definition.id)]: hold working — awaiting independent OCR absence frames " +
                    "(unknown=\(consecutiveOCRUnknownFrames)/2 inProgress=\(ocrInProgress))")
                break
            }

            // A status transition is proposed. Confirm across polls before
            // committing; the threshold depends on direction — upgrades react
            // fast (1), downgrades are cautious (3) to avoid false-idle flicker.
            // Attribute the transition only to evidence that actually supports
            // the proposed target. Previously AX-idle could label an
            // OCR-working transition as source=ax, which then defeated the
            // OCR-specific safety rules.
            let supportingEvidence = evidence.filter { $0.conclusion == target }
            let proposer = strongestSource(in: supportingEvidence) ?? .ocr
            let proposerConf = strongestConfidence(in: supportingEvidence)
            let threshold = isDowngrade(from: currentSnapshot.status, to: target)
                ? confirmThresholdDowngrade
                : confirmThresholdUpgrade

            if var p = pending, p.target == target {
                p.confirmations += 1
                pending = p  // write back the incremented counter (value type)
                Logger.shared.logDebug("AppWatcher[\(definition.id)]: pending \(currentSnapshot.status.label)→\(target.label) src=\(proposer.label) conf=\(String(format:"%.2f",proposerConf)) \(p.confirmations)/\(threshold)")
                if p.confirmations >= threshold {
                    pending = nil
                    let snap = StateSnapshot(status: target,
                                             evidenceSource: proposer,
                                             confidence: proposerConf)
                    commitSnapshot(snap, reason: "confirmed transition to \(target.label)")
                }
            } else {
                // New proposal (possibly replacing a different/direction one).
                // A fresh proposal already counts as 1 confirmation, so if the
                // threshold is 1 (upgrade) it can be confirmed immediately.
                let p = PendingTransition(target: target,
                                          source: proposer,
                                          confidence: proposerConf)
                pending = p
                Logger.shared.logDebug("AppWatcher[\(definition.id)]: proposing \(currentSnapshot.status.label)→\(target.label) src=\(proposer.label) conf=\(String(format:"%.2f",proposerConf)) \(p.confirmations)/\(threshold)")
                if p.confirmations >= threshold {
                    pending = nil
                    let snap = StateSnapshot(status: target,
                                             evidenceSource: proposer,
                                             confidence: proposerConf)
                    commitSnapshot(snap, reason: "confirmed transition to \(target.label)")
                }
            }
        }

        // --- 5. Fire attention signals detected by AX (continue/approval/...) ---
        //     These are event-level (notifications), distinct from the status
        //     machine. Dedup applied inside fireSignal.
        if let signal = detectedSignal {
            fireSignal(signal)
        }

        // Periodic heartbeat.
        if pollCount % 5 == 0 {
            Logger.shared.logDebug("AppWatcher[\(definition.id)]: status=\(currentSnapshot.status.label) src=\(currentSnapshot.evidenceSource.label) (poll #\(pollCount))")
        }
    }

    // MARK: - Commit

    /// Commits a new snapshot, firing state-change + working-transition
    /// signals only when the status actually changed.
    private func commitSnapshot(_ snapshot: StateSnapshot, reason: String) {
        let prevStatus = currentSnapshot.status

        // Working↔idle transition signals (mirror the old wasWorking behavior).
        if snapshot.status == .working && !wasWorking {
            wasWorking = true
            fireSignal(AttentionSignal(type: .workingStarted,
                                       reason: "智能体开始工作",
                                       elementSnippet: "",
                                       timestamp: Date()))
            Logger.shared.logInfo("AppWatcher[\(definition.id)]: idle → working")
        } else if snapshot.status != .working && wasWorking {
            // Leaving working (to idle/completed/needsAttention) = a round ended.
            // Only fire roundCompleted when going to idle/completed, not attention.
            if snapshot.status == .idle || snapshot.status == .completed {
                wasWorking = false
                fireSignal(AttentionSignal(type: .roundCompleted,
                                           reason: "智能体完成一轮工作",
                                           elementSnippet: "",
                                           timestamp: Date()))
                Logger.shared.logInfo("AppWatcher[\(definition.id)]: working → \(snapshot.status.label)")
            }
        }

        // Commit + notify on actual status change.
        if snapshot.status != prevStatus {
            Logger.shared.logInfo("AppWatcher[\(definition.id)]: status \(prevStatus.label) → \(snapshot.status.label) [\(reason)]")
            Logger.shared.logInfo("AppWatcher[\(definition.id)]: commit state \(snapshot.status.label)")
            currentSnapshot = snapshot
            notifyStateChange()
        } else {
            // Same status; just refresh provenance silently (no notification —
            // provenance churn must not cause UI flicker).
            currentSnapshot = snapshot
        }
    }

    /// Convenience: force the snapshot to idle when the app isn't running.
    private func commitIdleIfChanged(reason: String) {
        wasWorking = false
        let idle = StateSnapshot(status: .idle, evidenceSource: .ax, confidence: 1.0)
        if idle.status != currentSnapshot.status {
            Logger.shared.logInfo("AppWatcher[\(definition.id)]: status \(currentSnapshot.status.label) → idle [\(reason)]")
            currentSnapshot = idle
            notifyStateChange()
        } else {
            currentSnapshot = idle
        }
    }

    private func notifyStateChange() {
        delegate?.appWatcher(self, stateDidChangeTo: currentSnapshot)
    }

    // MARK: - Transition direction

    /// True when `from → to` is a downgrade — i.e. the agent is becoming LESS
    /// active/engaged. Downgrades need stricter pending confirmation so a single
    /// dropped frame or transient AX/OCR dropout can't falsely end a task.
    ///
    /// Defined explicitly per status pair (NOT via uiPriority) so the meaning is
    /// self-documenting and easy to audit:
    ///   - working → idle/completed        = downgrade (task wound down)
    ///   - needsAttention → idle/completed = downgrade (attention no longer needed)
    ///   - needsAttention → working        = downgrade (back to autonomous work)
    ///   - anything → needsAttention       = upgrade (needs human)
    ///   - idle → working/completed        = upgrade (became active)
    private func isDowngrade(from: AgentStatus, to: AgentStatus) -> Bool {
        switch (from, to) {
        case (.working, .idle), (.working, .completed):           return true
        case (.needsAttention, .idle), (.needsAttention, .completed),
             (.needsAttention, .working):                          return true
        default:                                                   return false
        }
    }

    /// Pure policy seam used by regression tests. An OCR-established working
    /// round may fall back to idle only after two distinct unknown OCR frames,
    /// and never while the next OCR frame is still being processed.
    static func shouldDeferOCRBackedWorkingExit(
        current: AgentStatus,
        target: AgentStatus,
        hasSeenOCRWorking: Bool,
        consecutiveOCRUnknownFrames: Int,
        ocrInProgress: Bool
    ) -> Bool {
        guard current == .working,
              target == .idle,
              hasSeenOCRWorking else { return false }
        return ocrInProgress || consecutiveOCRUnknownFrames < 2
    }

    // MARK: - OCR temporal handling

    /// OCR-frame handler: invoked exactly once per completed OCR run (from
    /// `runOCR`'s completion, on the watcher queue). All working-lease
    /// create/renew/clear/expire decisions and the cached evidence live here;
    /// `currentOCREvidence()` is a pure reader of the resulting state.
    ///
    /// Order of precedence:
    ///   1. expire stale lease first (`expireIfDue`)
    ///   2. terminal states (completed / needsAttention) clear the lease and
    ///      cache their verdict — they win over any lease and must never be
    ///      masked (a lease can't jump back from completed to working)
    ///   3. record the activity sample (novelty-gated)
    ///   4. explicit `.working` → cache working evidence + create/renew lease
    ///   5. unknown: drop any cached explicit working, then create/renew the
    ///      lease if activity-score ≥ threshold, else renew on text-change
    private func handleOCRResult(
        result: VisionDetector.OCRResult,
        observedAt: Date
    ) {
        ocrInProgress = false
        ocrResult = result
        lastOCRAt = observedAt

        let didExpire = temporal.expireIfDue(now: observedAt)

        // 先处理最高优先级终止状态
        switch result.state {
        case .completed:
            consecutiveOCRUnknownFrames = 0
            temporal.clearLease()
            cachedOCREvidence = makeEvidence(
                result,
                conclusion: .completed,
                observedAt: observedAt
            )
            logProcessed(result: result, observedAt: observedAt, lease: "cleared(completed)")
            return

        case .needsAttention:
            consecutiveOCRUnknownFrames = 0
            temporal.clearLease()
            cachedOCREvidence = makeEvidence(
                result,
                conclusion: .needsAttention,
                observedAt: observedAt
            )
            logProcessed(result: result, observedAt: observedAt, lease: "cleared(attention)")
            return

        case .working:
            hasSeenOCRWorking = true
            consecutiveOCRUnknownFrames = 0

        case .unknown:
            if hasSeenOCRWorking {
                consecutiveOCRUnknownFrames += 1
            }
        }

        temporal.recordFrame(
            score: result.activityScore,
            fingerprint: result.textFingerprint,
            now: observedAt
        )

        if result.state == .working {
            cachedOCREvidence = makeEvidence(
                result,
                conclusion: .working,
                observedAt: observedAt
            )

            if temporal.workingLease {
                temporal.renewLease(at: observedAt)
            } else {
                temporal.createLease(at: observedAt)
            }

            logProcessed(result: result, observedAt: observedAt, lease: "created/renewed")
            return
        }

        // 新 unknown 帧替换上一帧显式 working
        cachedOCREvidence = nil

        if temporal.activityWindowScore(now: observedAt)
            >= temporal.renewalThreshold {

            if temporal.workingLease {
                temporal.renewLease(at: observedAt)
            } else {
                temporal.createLease(at: observedAt)
            }

            logProcessed(result: result, observedAt: observedAt, lease: "created/renewed")
        } else if temporal.workingLease,
                  temporal.leaseAlive(now: observedAt),
                  temporal.fingerprintChanged() {

            temporal.renewLease(at: observedAt)
            logProcessed(result: result, observedAt: observedAt, lease: "renewed(text-change)")
        } else {
            logProcessed(result: result, observedAt: observedAt, lease: didExpire ? "expired" : "held/none")
        }
    }

    /// Builds an OCR `Evidence` from a verdict-bearing result.
    private func makeEvidence(_ result: VisionDetector.OCRResult,
                              conclusion: AgentStatus,
                              observedAt: Date) -> Evidence {
        Evidence(source: .ocr,
                 conclusion: conclusion,
                 confidence: result.confidence,
                 timestamp: observedAt,
                 snippet: result.matchedText)
    }

    /// One-line "OCR frame processed" log carrying appId + observedAt, the
    /// verdict, confidence, activity score and the lease outcome.
    private func logProcessed(result: VisionDetector.OCRResult,
                              observedAt: Date,
                              lease: String) {
        Logger.shared.logInfo("AppWatcher[\(definition.id)] OCR frame processed observedAt=\(ISO8601DateFormatter().string(from: observedAt)) state=\(result.state) conf=\(String(format: "%.2f", result.confidence)) activity=\(result.activityScore) lease=\(lease)")
    }

    // MARK: - OCR evidence reader

    /// Pure reader of the OCR/lease state set by `handleOCRResult`. Returns the
    /// cached explicit verdict while fresh, or a lease-held working evidence if
    /// a working lease is still alive; nil otherwise (fusion then falls back to
    /// AX). Never mutates state.
    private func currentOCREvidence() -> Evidence? {
        guard definition.rule.ocrRule != nil,
              let taken = lastOCRAt else { return nil }
        guard Date().timeIntervalSince(taken) < effectiveTTL() else {
            // Stale — let it lapse so the status isn't pinned by an old read.
            return nil
        }

        // Explicit verdict (working/completed/needsAttention) cached on the
        // frame that produced it. Terminal states must win over any stale lease.
        if let cached = cachedOCREvidence {
            return cached
        }

        // unknown frame + lease still alive → bridge the gap between OCR runs
        // with a low-confidence working evidence; the lease expires naturally
        // after OCRTemporalAggregator.windowSeconds, then the downgrade path
        // (3 consistent confirmations) takes over.
        if temporal.leaseAlive(now: Date()) {
            return Evidence(source: .ocr,
                            conclusion: .working,
                            confidence: 0.4,
                            timestamp: taken,
                            snippet: "lease-held")
        }

        return nil
    }

    /// Effective OCR-evidence TTL: floored at the rule's `backgroundInterval`
    /// + buffer so a detected working state stays put until the next OCR run
    /// (background apps are polled at the slow cadence and a short hintTTL
    /// would let the evidence lapse between runs).
    private func effectiveTTL() -> TimeInterval {
        let bg = definition.rule.ocrRule?.backgroundInterval ?? ocrIntervalBackground
        return max(definition.rule.ocrRule?.hintTTL ?? 8.0, bg + 3.0)
    }

    // MARK: - Fusion evidence helpers

    private func strongestSource(in evidence: [Evidence]) -> EvidenceSource? {
        return evidence.max(by: { $0.source.priority < $1.source.priority })?.source
    }

    private func strongestConfidence(in evidence: [Evidence]) -> Float {
        return evidence.map { $0.confidence }.max() ?? 0
    }

    private func reasonFor(_ axStatus: AgentStatus, _ ocr: Evidence?) -> String {
        if let ocr = ocr {
            return "ax=\(axStatus.label) ocr=\(ocr.conclusion.label)(\(String(format:"%.2f",ocr.confidence)))"
        }
        return "ax=\(axStatus.label)"
    }

    // MARK: - Signal Dispatch (with dedup)

    private func fireSignal(_ signal: AttentionSignal) {
        // Dedup: same signal type + snippet within dedupInterval → skip.
        if let last = lastDedup {
            if last.type == signal.type && last.snippet == signal.elementSnippet {
                let elapsed = Date().timeIntervalSince(last.time)
                if elapsed < dedupInterval {
                    Logger.shared.logDebug("AppWatcher[\(definition.id)]: dedup skip \(signal.type.label) (snippet=\(signal.elementSnippet))")
                    return
                }
            }
        }
        lastDedup = (type: signal.type,
                     snippet: signal.elementSnippet,
                     time: Date())
        Logger.shared.logInfo("AppWatcher[\(definition.id)]: signal \(signal.type.label) — \(signal.reason)")
        delegate?.appWatcher(self, didDetectSignal: signal)
    }
}
