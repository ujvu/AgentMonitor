import Foundation

// MARK: - Island Mode

/// The visual mode of the floating island.
///
/// Independent from the underlying `AgentStatus` (idle/working/needsAttention/
/// completed) — this is a *product-level* concept that drives the Dynamic
/// Island surface. Same agent status may map to different island modes
/// depending on UX rules (e.g. attention is always a persistent mode;
/// completed gets a 3s celebration then collapses).
///
/// - dormant:     no agent active; a thin sliver at the very top
/// - peek:        user hovered the island while idle → show what's running
/// - active:      an agent is working; persistent card until done
/// - attention:   an agent needs the user; persistent until resolved
/// - celebration: a task just finished; brief showcase then auto-collapse
enum IslandMode: Equatable {
    case dormant
    case peek
    case active
    case attention
    case celebration
}

// MARK: - Island Animation

/// Animation hint for the visual layer. The actual animation lives in
/// `IslandAnimationEngine` (planned Phase 3). For now this is a label the
/// rendering layer can switch on.
enum IslandAnimation: Equatable {
    case idle        // dormant: subtle breathing or none
    case breathing   // peek/hover preview: slow breathing blink + content glow
    case working     // active: flowing energy bar
    case alert       // attention: pulsing border
    case complete    // celebration: brief flash, fade
}

// MARK: - Island Scene

/// A fully-rendered scene description for the island: what to show, how to
/// animate it, and where to slot it in.
///
/// Built by `IslandPresentationEngine` from a `StateEvent` + `AppDefinition`.
/// The rendering layer (`FloatingIsland`) only ever sees an `IslandScene` —
/// it never re-decides status, never picks agents, never authors strings.
///
/// v9 split: state detection lives in the status layer (AX/OCR/Fusion); the
/// presentation layer owns the *product* — modes, copy, animation choice.
struct IslandScene: Equatable {
    /// Which surface to render.
    let mode: IslandMode
    /// Short uppercase title (e.g. "Z CODE", "千问办公").
    let title: String
    /// Optional second line — status word ("WORKING", "NEED ACTION") or a
    /// brief reason. `nil` means the renderer hides the second line.
    let subtitle: String?
    /// Glyph for the icon slot. ASCII for now; a later phase can swap in
    /// pixel sprites.
    let icon: String
    /// Animation hint the renderer should apply.
    let animation: IslandAnimation
    /// Used by multi-agent rotation: higher number wins. Mirrors
    /// `AgentStatus.uiPriority` so attention > working > completed > idle.
    let priority: Int
    /// Source app id — kept for click-through activation and debugging.
    let appId: String

    /// True when this scene is worth showing (active / attention / celebration).
    /// Idle scenes are excluded from the scene array the renderer consumes.
    var isActionable: Bool {
        switch mode {
        case .dormant, .peek: return false
        case .active, .attention, .celebration: return true
        }
    }
}