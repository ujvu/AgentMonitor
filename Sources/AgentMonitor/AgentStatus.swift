import Foundation

// MARK: - AgentStatus

/// The pure business status of a watched agent app.
///
/// This enum carries NO evidence/source/confidence — it answers only
/// "what state is the agent in?". Separating status from evidence (see
/// `StateSnapshot` / `Evidence`) keeps state-change detection stable: a status
/// flip is a real cognitive change, while source/confidence/timestamp churn is
/// just new information about the same status and must NOT trigger UI refresh.
enum AgentStatus: String, Equatable {
    case idle
    case working
    case needsAttention
    case completed

    /// Human-readable label used in logs.
    var label: String { rawValue }

    /// Business priority for fusion: higher wins. This is distinct from
    /// `EvidenceSource.priority` (which ranks data sources). `uiPriority`
    /// ranks the *conclusions*: a "needsAttention" conclusion always outranks
    /// a "completed" one regardless of where the evidence came from.
    var uiPriority: Int {
        switch self {
        case .needsAttention: return 40
        case .completed:      return 30
        case .working:        return 20
        case .idle:           return 10
        }
    }
}

// MARK: - EvidenceSource

/// Where a piece of evidence came from. Each source carries a priority that
/// the fusion engine uses when resolving same-conclusion agreement or weighing
/// conflicting sources. New sources (AppleScript, log parsing, API, …) extend
/// this enum with their own priority.
enum EvidenceSource: Equatable {
    case ax
    case ocr

    /// Data-source reliability weight. AX (live accessibility tree) is the most
    /// trusted live source; OCR (vision text recognition) is a best-effort hint.
    var priority: Int {
        switch self {
        case .ax:  return 100
        case .ocr: return 70
        }
    }

    var label: String {
        switch self {
        case .ax:  return "ax"
        case .ocr: return "ocr"
        }
    }
}

// MARK: - Evidence

/// A single observation from one source concluding that the agent is in
/// `conclusion`. Evidence is the input to fusion; it never gets stored as "the
/// state" directly.
struct Evidence: Equatable {
    let source: EvidenceSource
    let conclusion: AgentStatus
    /// 0...1. AX evidence is deterministic → 1.0. OCR carries its real
    /// recognition confidence.
    let confidence: Float
    let timestamp: Date
    /// Short human-readable hint about what matched (button title, OCR line).
    let snippet: String
}

// MARK: - StateSnapshot

/// The fused cognitive snapshot: what we believe the agent's status is, plus
/// the provenance (source/confidence/timestamp) of that belief.
///
/// Equatable is deliberately defined to compare ONLY `status`. Two snapshots
/// with the same status but different source/confidence/timestamp are
/// considered equal so that provenance churn does not masquerade as a state
/// change — this is what prevents duplicate UI refreshes / notifications.
struct StateSnapshot: Equatable {
    let status: AgentStatus
    let evidenceSource: EvidenceSource
    let confidence: Float
    let timestamp: Date

    init(status: AgentStatus,
         evidenceSource: EvidenceSource = .ax,
         confidence: Float = 1.0,
         timestamp: Date = Date()) {
        self.status = status
        self.evidenceSource = evidenceSource
        self.confidence = confidence
        self.timestamp = timestamp
    }

    /// Convenience: initial idle snapshot at app start.
    static let initialIdle = StateSnapshot(status: .idle)

    /// Convenience accessor forwarding to the status label (logs/UI).
    var label: String { status.label }

    /// Convenience snapshots for each status, so call sites can write
    /// `.idle` / `.working` / `.needsAttention` / `.completed` as before.
    static let idle = StateSnapshot(status: .idle)
    static let working = StateSnapshot(status: .working)
    static let needsAttention = StateSnapshot(status: .needsAttention)
    static let completed = StateSnapshot(status: .completed)

    /// Equality on status ONLY — see class docs.
    static func == (lhs: StateSnapshot, rhs: StateSnapshot) -> Bool {
        return lhs.status == rhs.status
    }
}

/// Backwards-compat alias so existing call sites (`var state: WatcherState`)
/// keep compiling while we migrate consumers. A `WatcherState` IS a snapshot.
typealias WatcherState = StateSnapshot

// MARK: - FusionResult

/// The fusion engine's verdict for one poll. It NEVER returns "pending" —
/// pending is a transition-control concern owned by `AppWatcher`. Fusion only
/// judges the most credible status right now and, if it differs from current,
/// *proposes* a transition for the caller to confirm.
indirect enum FusionResult: Equatable {
    /// The current status is still the most credible; refresh provenance.
    case stable(StateSnapshot)
    /// A higher-priority conclusion was observed; the caller should confirm it
    /// (via PendingManager) before committing.
    case transitionNeeded(target: AgentStatus, evidence: [Evidence])
}

// MARK: - PendingTransition

/// An in-flight, not-yet-confirmed status change. Tracked so that a single
/// OCR misread or a transient AX/OCR dropout can't flip the perceived status
/// — the change must be re-asserted across enough polls to be trusted.
struct PendingTransition {
    let target: AgentStatus
    let source: EvidenceSource
    let confidence: Float
    let firstSeen: Date
    var confirmations: Int

    init(target: AgentStatus,
         source: EvidenceSource,
         confidence: Float,
         firstSeen: Date = Date(),
         confirmations: Int = 1) {
        self.target = target
        self.source = source
        self.confidence = confidence
        self.firstSeen = firstSeen
        self.confirmations = confirmations
    }
}

// MARK: - StateEvent

/// A committed status change, broadcast on the state-event bus. This is the
/// single stream that UI surfaces (Dynamic Island, pixel panel), history, and
/// notifications subscribe to — so adding a new consumer requires no change to
/// detection/fusion code.
struct StateEvent {
    let appId: String
    let old: AgentStatus
    let new: AgentStatus
    let snapshot: StateSnapshot
    /// Short human-readable reason, e.g. "OCR 匹配「任务完成」".
    let reason: String
}
