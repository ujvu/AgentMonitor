import Foundation

// MARK: - IslandPresentationEngine

/// Product-experience layer that converts state-layer events into
/// `IslandScene`s the visual layer can render.
///
/// ### Why this exists (v9 architecture)
///
/// ```
/// AXDetector / OCRDetector        — status sensing
///        ↓
/// FusionEngine                     — status evidence
///        ↓
/// AppWatcher                       — commits StateSnapshot, fires StateEvent
///        ↓
/// IslandPresentationEngine  ⭐     — THIS FILE: state → product scene
///        ↓
/// FloatingIsland                   — renders the IslandScene
///        ↓
/// (planned) IslandAnimationEngine  — drives the IslandAnimation
/// ```
///
/// FloatingIsland used to mix four concerns (status judging, agent picking,
/// animation choice, drawing). v9 splits those so the visual layer becomes
/// purely declarative: "show this scene, don't re-decide anything".
///
/// ### Phase 1 status
///
/// This file is added in Phase 1 with a pure `present(_:app:)` function and
/// a `demoRunSelfTest()` helper. FloatingIsland is *not* rewired yet — it
/// still drives itself from `AgentStatus`. Phase 2 will migrate
/// FloatingIsland's `handleStateChanged` / `handleSignal` paths to consume
/// `IslandScene` instead.
final class IslandPresentationEngine {

    // MARK: - Pure transform (state → scene)

    /// Build the `IslandScene` for a single state transition.
    ///
    /// `previous` is used to disambiguate the "completed" case: we want a
    /// 3-second celebration (vs. a long-lived active card). If the previous
    /// status was `working`, this transition *is* a completion → celebration.
    /// If the previous was `idle`/`completed`, the agent's status just
    /// re-asserted and we treat it as the appropriate persistent mode.
    func present(stateEvent: StateEvent,
                 app: AppDefinition,
                 previous: AgentStatus?) -> IslandScene {
        let newStatus = stateEvent.new
        let appName = app.displayName

        switch newStatus {
        case .working:
            return IslandScene(
                mode: .active,
                title: appName.uppercased(),
                subtitle: "WORKING",
                icon: "robot_working",
                animation: .working,
                priority: 20,
                appId: app.id
            )

        case .needsAttention:
            return IslandScene(
                mode: .attention,
                title: appName.uppercased(),
                subtitle: "NEED ACTION",
                icon: "robot_attention",
                animation: .alert,
                priority: 40,
                appId: app.id
            )

        case .completed:
            // Only celebrate when this transition *just* finished work.
            // Re-asserting completed from idle should still show celebration
            // briefly so the user sees the "done" message.
            _ = previous // currently unused; future tuning may distinguish
            return IslandScene(
                mode: .celebration,
                title: appName.uppercased(),
                subtitle: "DONE",
                icon: "robot_complete",
                animation: .complete,
                priority: 30,
                appId: app.id
            )

        case .idle:
            return IslandScene(
                mode: .dormant,
                title: appName.uppercased(),
                subtitle: nil,
                icon: "robot_idle",
                animation: .idle,
                priority: 10,
                appId: app.id
            )
        }
    }

    // MARK: - Convenience: present without a previous status

    /// Build a scene from just the *current* status (no transition context).
    /// Used when rendering the featured agent on hover-peek or when starting
    /// cold (no previous transition recorded).
    func present(currentStatus: AgentStatus, app: AppDefinition) -> IslandScene {
        // Synthesize a self-event so the same switch logic applies.
        let synthetic = StateEvent(
            appId: app.id,
            old: .idle,
            new: currentStatus,
            snapshot: StateSnapshot(status: currentStatus),
            reason: "synthetic"
        )
        return present(stateEvent: synthetic, app: app, previous: nil)
    }

    // MARK: - Multi-agent scene array

    /// Builds the full set of actionable scenes for all watched apps, sorted by
    /// priority (attention > celebration > active). Idle apps produce no scene,
    /// so the renderer never shows an "idle" card — the array only expresses
    /// what is worth looking at right now.
    ///
    /// The renderer consumes this array directly (featured = first, rotation =
    /// iterate); it never re-decides status or re-authors strings.
    func presentScenes(for apps: [AppDefinition],
                       engine: MonitorEngine) -> [IslandScene] {
        let scenes: [IslandScene] = apps.compactMap { app in
            let snap = engine.stateForApp(app)
            let scene = present(currentStatus: snap.status, app: app)
            return scene.isActionable ? scene : nil
        }
        // attention (40) > celebration (30) > active (20).
        return scenes.sorted { $0.priority > $1.priority }
    }

    // MARK: - Hover preview (peek)

    /// Builds the hover-preview scene for an agent that currently has no
    /// actionable state (e.g. all agents idle and the user hovers the island).
    ///
    /// Product-layer only: no `idle` business animation — preview uses the
    /// `breathing` animation semantics so the card reads as "preview", not
    /// "status report". The renderer must NEVER fall back to nil when no
    /// actionable scene exists; this is the scene it shows instead.
    func peekScene(for app: AppDefinition) -> IslandScene {
        IslandScene(
            mode: .peek,
            title: app.displayName.uppercased(),
            subtitle: nil,
            icon: "robot_peek",
            animation: .breathing,
            priority: 10,
            appId: app.id
        )
    }

    // MARK: - Self test (Phase 1 verification)

    /// Phase 1 verification harness: synthesizes one transition per
    /// `AgentStatus` and logs the resulting `IslandScene` so we can confirm
    /// the state→scene mapping is correct before Phase 2 rewires the UI.
    ///
    /// Called once at app start (from `AppDelegate`) so the log file always
    /// shows the current mapping without needing to trigger a real task.
    static func demoRunSelfTest() {
        let engine = IslandPresentationEngine()

        // Borrow a real AppDefinition per watched app so the title is real.
        // We only need displayName + id; the full rule payload is unused here.
        let sampleApps: [(label: String, app: AppDefinition)] = [
            ("WorkBuddy (working)", AppDefinition(
                id: "workbuddy", displayName: "WorkBuddy",
                bundleId: "com.workbuddy.workbuddy", processName: "Electron",
                rule: AppRule(
                    continueSignals: [], approvalSignals: [], workingSignals: [],
                    completionSignals: [], stopSignals: [], sendButtonSignals: []))),
            ("Z Code (attention)", AppDefinition(
                id: "zcode", displayName: "Z Code",
                bundleId: "dev.zcode.app", processName: "ZCode",
                rule: AppRule(
                    continueSignals: [], approvalSignals: [], workingSignals: [],
                    completionSignals: [], stopSignals: [], sendButtonSignals: []))),
            ("ChatGPT (completed)", AppDefinition(
                id: "chatgpt", displayName: "ChatGPT",
                bundleId: "com.openai.codex", processName: "Codex",
                rule: AppRule(
                    continueSignals: [], approvalSignals: [], workingSignals: [],
                    completionSignals: [], stopSignals: [], sendButtonSignals: []))),
            ("千问办公 (idle)", AppDefinition(
                id: "qwenwork", displayName: "千问办公",
                bundleId: "cn.qwenwork.desktop.mac", processName: "QwenWork",
                rule: AppRule(
                    continueSignals: [], approvalSignals: [], workingSignals: [],
                    completionSignals: [], stopSignals: [], sendButtonSignals: []))),
        ]

        Logger.shared.logInfo("=== IslandPresentationEngine self-test BEGIN ===")
        for entry in sampleApps {
            let newStatus: AgentStatus
            switch entry.app.id {
            case "workbuddy": newStatus = .working
            case "zcode":      newStatus = .needsAttention
            case "chatgpt":    newStatus = .completed
            default:           newStatus = .idle
            }
            let previous: AgentStatus = (newStatus == .completed) ? .working : .idle
            let event = StateEvent(
                appId: entry.app.id,
                old: previous,
                new: newStatus,
                snapshot: StateSnapshot(status: newStatus),
                reason: "self-test"
            )
            let scene = engine.present(stateEvent: event, app: entry.app, previous: previous)
            log(scene: scene, from: entry.label)
        }
        Logger.shared.logInfo("=== IslandPresentationEngine self-test END ===")
    }

    private static func log(scene: IslandScene, from label: String) {
        Logger.shared.logInfo(
            "StateEvent \(label)\n      ↓\n"
            + "IslandScene: mode=\(modeLabel(scene.mode)) "
            + "title=\"\(scene.title)\" subtitle=\(scene.subtitle ?? "nil") "
            + "icon=\(scene.icon) animation=\(animLabel(scene.animation)) "
            + "priority=\(scene.priority) appId=\(scene.appId)"
        )
    }

    private static func modeLabel(_ m: IslandMode) -> String {
        switch m {
        case .dormant:     return "DORMANT"
        case .peek:        return "PEEK"
        case .active:      return "ACTIVE"
        case .attention:   return "ATTENTION"
        case .celebration: return "CELEBRATION"
        }
    }

    private static func animLabel(_ a: IslandAnimation) -> String {
        switch a {
        case .idle:      return "idle"
        case .breathing: return "breathing"
        case .working:   return "working"
        case .alert:     return "alert"
        case .complete:  return "complete"
        }
    }
}