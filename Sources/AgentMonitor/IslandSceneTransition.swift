import Foundation

// MARK: - IslandSceneTransition

/// Cross-fades the rendered `IslandScene` while keeping the window geometry
/// untouched. Used by `IslandRotationManager` to switch between multiple
/// active agents (Z Code → WorkBuddy → ...) without re-opening the island.
///
/// Lifecycle:
/// 1. **Fade out**: engine drives `contentAlpha` 1→0 at the current geometry
///    (phase `.contentFadeOut`). The current scene is still visible while it
///    fades.
/// 2. **Scene swap**: after the fade-out duration elapses on the main queue,
///    `container.currentScene` is replaced with the new scene. Geometry stays
///    exactly where it was — no frame change, no re-expansion.
/// 3. **Fade in**: engine drives `contentAlpha` 0→1 (phase `.contentFadeIn`),
///    revealing the new scene.
///
/// Implementation note: the swap is scheduled via `DispatchQueue.main.asyncAfter`
/// against `fadeOut` rather than chaining through the engine's `onComplete`.
/// The engine's `onComplete` is a single callback owned by `FloatingIsland`
/// for the show/hide lifecycle (e.g. `pendingHide` → `orderOut`); we don't
/// want to multiplex it. asyncAfter is sufficient because the engine's
/// `sequenceId` cancellation will already drop the queued fade-in frame if a
/// new show/hide arrives mid-transition — leaving `currentScene` in whatever
/// state it was at cancel time, which is the desired "latest-wins" behavior.
final class IslandSceneTransition {

    /// Engine that drives the contentAlpha interpolation.
    private let animationEngine: IslandAnimationEngine
    /// Receives the scene swap at the boundary between fade-out and fade-in.
    private weak var containerSceneSetter: SceneSetter?

    init(animationEngine: IslandAnimationEngine,
         containerSceneSetter: SceneSetter) {
        self.animationEngine = animationEngine
        self.containerSceneSetter = containerSceneSetter
    }

    /// Begins a cross-fade from the current scene to `next`. The geometry at
    /// the moment of the call is captured and held constant throughout — no
    /// re-opening of the island. If a transition is already in progress, the
    /// new request cancels it via the engine's `sequenceId` mechanism.
    func crossFade(to next: IslandScene,
                   currentGeometry geometry: (size: NSSize, cornerRadius: CGFloat),
                   fadeOut: TimeInterval = 0.15,
                   fadeIn: TimeInterval = 0.15) {
        let nextId = next.appId
        Logger.shared.logInfo("transition: fadeOut begin (next=\(nextId), duration=\(Int(fadeOut*1000))ms, geometry held)")

        // Schedule the scene swap at the fade-out boundary. asyncAfter is
        // dispatched on main (where the engine's morph frames also land), so
        // the timing lines up with the engine's progress even though they
        // are not formally sequenced.
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeOut) { [weak self] in
            self?.containerSceneSetter?.setCurrentScene(next)
            Logger.shared.logInfo("transition: scene swap → \(nextId) (geometry held across swap)")
        }

        animationEngine.morphSequence([
            // Step 1: hold geometry, fade content out.
            IslandMorphStep(target: IslandMorphTarget(size: geometry.size,
                                                      cornerRadius: geometry.cornerRadius,
                                                      contentAlpha: 0),
                            phase: .contentFadeOut, duration: fadeOut),
            // Step 2: hold geometry, fade content in. The scene swap above
            // runs at the boundary between step 1 and step 2.
            IslandMorphStep(target: IslandMorphTarget(size: geometry.size,
                                                      cornerRadius: geometry.cornerRadius,
                                                      contentAlpha: 1),
                            phase: .contentFadeIn, duration: fadeIn)
        ])
        // fadeIn is the engine's step 2; it starts at t=fadeOut. Log here so
        // the timeline reads fadeOut begin → scene swap → fadeIn begin, with
        // geometry held constant throughout (no .awakening / .collapsing).
        Logger.shared.logInfo("transition: fadeIn begin (next=\(nextId), duration=\(Int(fadeIn*1000))ms, geometry held)")
    }
}

/// Tiny protocol so `IslandSceneTransition` can swap the rendered scene
/// without taking a hard dependency on `FloatingIslandContainer`. The
/// container's `currentScene` setter already triggers `needsDisplay`.
protocol SceneSetter: AnyObject {
    func setCurrentScene(_ scene: IslandScene)
}