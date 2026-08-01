import Foundation

/// Pure-function state fusion. Given the current cognitive status and the
/// latest evidence from AX (and optionally OCR), decide what we believe right
/// now and whether a status transition should be *proposed*.
///
/// Design rules (from architecture review):
///   1. `needsAttention` always wins (any source).
///   2. `completed` outranks OCR-derived `working`.
///   3. AX-derived `working` outranks OCR-derived `working` (handled via source
///      priority when the two agree on working but disagree on nothing else).
///   4. OCR only supplements what AX cannot tell us — when AX has no strong
///      conclusion, OCR may lift idle → working/needsAttention/completed.
///   5. Fusion NEVER returns "pending". It returns `.transitionNeeded` for any
///      candidate that differs from current (upgrade OR downgrade); the caller
///      confirms via pending, using a stricter threshold for downgrades.
///
/// `target` is always the higher `uiPriority` candidate: if AX still reports
/// working during the confirmation window, AX evidence keeps arriving and the
/// pending transition fails to confirm — so AX never silently "loses".
enum FusionEngine {

    /// Fuse AX + OCR evidence against the current status.
    ///
    /// - Parameters:
    ///   - current: The agent's currently-committed status.
    ///   - axEvidence: Latest AX conclusion (may be nil if the window is gone).
    ///   - ocrEvidence: Latest OCR conclusion, or nil when no rule / stale.
    /// - Returns: `.stable` to hold/refresh current, or `.transitionNeeded` to
    ///   propose upgrading to a higher-priority status (caller confirms).
    static func fuse(current: AgentStatus,
                     axEvidence: Evidence?,
                     ocrEvidence: Evidence?) -> FusionResult {
        // Collect only evidence that actually asserts a conclusion.
        // (AX can legitimately return nothing when the window is inaccessible.)
        let allEvidence = [axEvidence, ocrEvidence].compactMap { $0 }

        // No evidence at all → hold current (avoids false-idle from dropout).
        guard !allEvidence.isEmpty else {
            return .stable(StateSnapshot(status: current))
        }

        // Pick the candidate: the conclusion with the highest business priority.
        // On a tie, prefer the higher source priority (AX > OCR).
        let candidate = allEvidence.reduce(into: allEvidence[0]) { best, ev in
            if ev.conclusion.uiPriority > best.conclusion.uiPriority ||
               (ev.conclusion.uiPriority == best.conclusion.uiPriority &&
                ev.source.priority > best.source.priority) {
                best = ev
            }
        }

        // --- Decide based on candidate vs current ---
        //
        // Fusion's only job is to propose a target status from the evidence. It
        // does NOT decide whether a transition is allowed — that's the caller's
        // (PendingManager's) job. So any candidate that differs from current is
        // returned as `.transitionNeeded`, regardless of upgrade or downgrade
        // direction. Blocking downgrades here caused a deadlock where working
        // could never return to idle once committed.
        if candidate.conclusion == current {
            // Same status; refresh provenance from the winning evidence.
            return .stable(StateSnapshot(status: current,
                                         evidenceSource: candidate.source,
                                         confidence: candidate.confidence,
                                         timestamp: candidate.timestamp))
        }

        // Different candidate (upgrade OR downgrade) → propose the transition;
        // the caller confirms via pending, applying a stricter threshold for
        // downgrades to avoid false-idle flicker.
        return .transitionNeeded(target: candidate.conclusion, evidence: allEvidence)
    }
}
