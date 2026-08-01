import Foundation
import ApplicationServices

/// The type of attention signal detected from an agent app.
enum SignalType {
    case workingStarted
    case roundCompleted
    case needsContinue
    case needsApproval
    case needsChoice
    case completionIndicator
}

extension SignalType {
    var label: String {
        switch self {
        case .workingStarted:      return "workingStarted"
        case .roundCompleted:      return "roundCompleted"
        case .needsContinue:       return "needsContinue"
        case .needsApproval:       return "needsApproval"
        case .needsChoice:         return "needsChoice"
        case .completionIndicator: return "completionIndicator"
        }
    }
}

/// A single attention signal emitted by the detector.
struct AttentionSignal {
    let type: SignalType
    let reason: String
    let elementSnippet: String
    let timestamp: Date
}

// MARK: - WatcherState
//
// `WatcherState` (the high-level state of a watched app) now lives in
// AgentStatus.swift as an alias for `StateSnapshot` (status + provenance). The
// pure-status enum is `AgentStatus`. See AgentStatus.swift for the rationale of
// separating status from evidence.

/// Multi-signal detection engine that uses `AppDefinition` rules.
///
/// This is a stateless utility type (enum) with static methods. All mutable
/// tracking (last-send-enabled, last-timer-text, completion snippets) is
/// owned by the caller (`AppWatcher`) and threaded through via `inout`
/// parameters so that no shared mutable state leaks across apps.
enum SignalDetector {

    /// Tracks the last-seen completion snippet per app id, used to avoid
    /// re-firing the same completion indicator poll after poll.
    static var lastCompletionSnippets: [String: Set<String>] = [:]

    /// Tracks how many consecutive polls the working-timer text has stayed
    /// unchanged per app id. When it stalls beyond `stallThreshold`, the task
    /// is treated as finished (idle) instead of perpetually working.
    /// Keyed by app id to isolate each app.
    static var workingTimerStallCount: [String: Int] = [:]

    /// Number of consecutive unchanged polls before a stalled working indicator
    /// is treated as a finished task. At a 2s poll interval, 3 ≈ 6 seconds.
    private static let stallThreshold = 3

    /// Max length (in characters) of a single AX attribute string for it to be
    /// treated as a working indicator. Real indicators are short status labels
    /// (e.g. "已工作 3m 20s", "正在生成…", "Thinking"). Long strings are almost
    /// always conversation messages or draft text that merely *mention* the
    /// keyword — matching those causes false workingStarted loops. 40 chars
    /// comfortably covers the longest real indicator while excluding paragraphs.
    private static let maxWorkingIndicatorLength = 40

    // MARK: - Main Entry Point

    /// Inspects a single app's accessibility tree and returns any attention
    /// signal detected, updating the caller-owned tracking state.
    ///
    /// Operates on `AgentStatus` (the pure status enum) — provenance is decided
    /// by the caller's fusion layer. The AX detection logic itself is unchanged.
    ///
    /// - Parameters:
    ///   - app: The AXUIElement for the running application.
    ///   - definition: The `AppDefinition` with matching rules.
    ///   - state: inout current `AgentStatus` (updated in place).
    ///   - lastSendEnabled: inout last-known send-button enabled state.
    ///   - lastTimerText: inout last-seen working-timer text.
    /// - Returns: An `AttentionSignal` if one was detected, else `nil`.
    static func detect(app: AXUIElement,
                       definition: AppDefinition,
                       state: inout AgentStatus,
                       lastSendEnabled: inout Bool,
                       lastTimerText: inout String?) -> AttentionSignal? {

        guard let window = AXUtilities.focusedWindow(of: app) else {
            // Window not accessible — don't change state, don't crash.
            return nil
        }

        // --- Check order ---

        // 1) Continue signals (buttonOnly filter)
        if let btn = matchFirstPattern(definition.rule.continueSignals, in: window) {
            state = .needsAttention
            let snip = snippet(of: btn)
            Logger.shared.logInfo("SignalDetector[\(definition.id)]: needsContinue — \(snip)")
            return AttentionSignal(type: .needsContinue,
                                    reason: "检测到「继续」按钮，等待用户点击继续",
                                    elementSnippet: snip,
                                    timestamp: Date())
        }

        // 2) Approval signals (buttonOnly)
        if let btn = matchFirstPattern(definition.rule.approvalSignals, in: window) {
            state = .needsAttention
            let snip = snippet(of: btn)
            Logger.shared.logInfo("SignalDetector[\(definition.id)]: needsApproval — \(snip)")
            return AttentionSignal(type: .needsApproval,
                                    reason: "检测到审批/确认按钮，等待用户授权",
                                    elementSnippet: snip,
                                    timestamp: Date())
        }

        // 3) New completion indicators (any element, track all seen in a Set)
        var completionSignal: AttentionSignal? = nil
        if let el = matchFirstPattern(definition.rule.completionSignals, in: window) {
            let snip = snippet(of: el)
            let wasEmpty = (lastCompletionSnippets[definition.id]?.isEmpty ?? true)
            if lastCompletionSnippets[definition.id]?.contains(snip) != true {
                lastCompletionSnippets[definition.id, default: []].insert(snip)
                // Don't fire on the very first scan — those are historical
                // completions already in the conversation, not new ones.
                if !wasEmpty {
                    completionSignal = AttentionSignal(type: .completionIndicator,
                                                      reason: "检测到完成标志",
                                                      elementSnippet: snip,
                                                      timestamp: Date())
                    Logger.shared.logInfo("SignalDetector[\(definition.id)]: completionIndicator — \(snip)")
                }
            }
        }

        // 4) Send button state transition (track only; state transitions are
        //    handled by AppWatcher via workingStarted/roundCompleted).
        if !definition.rule.sendButtonSignals.isEmpty {
            if let sendBtn = matchFirstPattern(definition.rule.sendButtonSignals, in: window) {
                lastSendEnabled = AXUtilities.isEnabled(sendBtn)
            }
        }

        // After all signal checks, update the working state.
        updateWorkingState(definition: definition,
                           window: window,
                           state: &state,
                           lastSendEnabled: &lastSendEnabled,
                           lastTimerText: &lastTimerText)

        if completionSignal != nil {
            Logger.shared.logDebug("SignalDetector[\(definition.id)]: state=\(state.label) completion=yes")
        }

        return completionSignal
    }

    // MARK: - Working State

    /// Determines whether the app is currently `working` or `idle`.
    ///
    /// Check order:
    /// 1. Stop button present → working
    /// 2. Working indicator text with TIME words → working
    /// 3. Send button disabled → working
    /// 4. else → idle
    static func updateWorkingState(definition: AppDefinition,
                                   window: AXUIElement,
                                   state: inout AgentStatus,
                                   lastSendEnabled: inout Bool,
                                   lastTimerText: inout String?) {

        // 1. Stop button presence → working
        if matchFirstPattern(definition.rule.stopSignals, in: window) != nil {
            state = .working
            return
        }

        // 2. Working indicator text — uses the app's own workingSignals keywords.
        //    This includes "Loading", "正在生成", "已工作", etc.
        //    NEVER match "新建任务中" — it is a static sidebar label.
        //
        //    Freshness guard: historical conversation text often lingers with a
        //    fixed "已工作 3m 20s" string, which would otherwise pin the app in
        //    `.working` forever and never let it return to idle. So we only count
        //    the app as working while the indicator text is actively changing
        //    (the timer is ticking). Once it stalls for `stallThreshold` polls,
        //    we treat the task as finished and fall through to the idle state.
        if let timerText = findWorkingIndicatorText(definition: definition, in: window) {
            if !timerText.contains("新建任务中") {
                let workingKeywords = definition.workingIndicatorPatterns
                let lower = timerText.lowercased()
                if workingKeywords.contains(where: { lower.contains($0.lowercased()) }) {
                    if isWorkingIndicatorFresh(appId: definition.id,
                                               text: timerText,
                                               lastTimerText: &lastTimerText) {
                        state = .working
                        return
                    }
                    // Stalled — treat as finished: fall through to idle below,
                    // but also let the send-button check (rule 3) have a say.
                }
            }
        }

        // (The working-timer freshness check above replaces the old no-op
        // checkWorkingTimer call: stalling indicators now fall through here.)

        // 3. Send button disabled → working
        if !definition.rule.sendButtonSignals.isEmpty {
            if let sendBtn = matchFirstPattern(definition.rule.sendButtonSignals, in: window) {
                let enabled = AXUtilities.isEnabled(sendBtn)
                lastSendEnabled = enabled
                if !enabled {
                    state = .working
                    return
                }
            }
        }

        // 4. else → idle. Reset the stall counter and timer memory so the next
        //    working session starts fresh.
        workingTimerStallCount[definition.id] = 0
        lastTimerText = nil
        state = .idle
    }

    /// Decides whether a matched working-indicator text means the app is still
    /// actively working, or whether the text has stalled (e.g. a leftover
    /// "已工作 3m 20s" from a finished task lingering in conversation history).
    ///
    /// - When the text changes between polls (timer ticking) → fresh, working.
    ///   Resets the stall counter.
    /// - When the text is identical to last poll → increment stall counter.
    ///   Still considered working until `stallThreshold` consecutive stalls,
    ///   after which it returns false so the caller falls through to idle.
    ///
    /// `lastTimerText` is updated in place to the current text on every call.
    private static func isWorkingIndicatorFresh(appId: String,
                                                text: String,
                                                lastTimerText: inout String?) -> Bool {
        let prev = lastTimerText
        lastTimerText = text

        if prev != text {
            // Text is changing — timer is ticking. Reset stall count.
            workingTimerStallCount[appId] = 0
            Logger.shared.logDebug("SignalDetector[\(appId)]: working text changed → fresh (\(text))")
            return true
        }

        // Same text as last poll — accumulate stall.
        let stalls = (workingTimerStallCount[appId] ?? 0) + 1
        workingTimerStallCount[appId] = stalls
        if stalls < stallThreshold {
            Logger.shared.logDebug("SignalDetector[\(appId)]: working text unchanged (stall \(stalls)/\(stallThreshold)) → still working")
            return true
        }
        Logger.shared.logInfo("SignalDetector[\(appId)]: working text stalled for \(stalls) polls → treating as finished")
        return false
    }

    // MARK: - Pattern Matching Helpers

    /// Returns the first element matching any of the given patterns, or nil.
    static func matchFirstPattern(_ patterns: [SignalPattern],
                                  in window: AXUIElement?) -> AXUIElement? {
        for pattern in patterns {
            if let el = matchPattern(pattern, in: window) {
                return el
            }
        }
        return nil
    }

    /// Searches the accessibility tree for the first element matching a single
    /// `SignalPattern`. Respects the pattern's role list, match mode, and
    /// context filter.
    static func matchPattern(_ pattern: SignalPattern,
                             in window: AXUIElement?) -> AXUIElement? {
        guard let window = window else { return nil }

        let buttonRoles: Set<String> = [
            "AXButton", "AXPopUpButton", "AXCheckBox",
            "AXMenuBarItem", "AXMenuItem", "AXMenuButton", "AXToolbarItem"
        ]

        let matches = AXUtilities.searchTree(window, maxDepth: 25) { el in
            // Context filter: buttonOnly requires a button-like role even if
            // the pattern's roles list is empty.
            if pattern.contextFilter == .buttonOnly {
                guard let r = AXUtilities.role(el), buttonRoles.contains(r) else {
                    return false
                }
            }
            // Role constraint.
            if !pattern.roles.isEmpty {
                guard let r = AXUtilities.role(el), pattern.roles.contains(r) else {
                    return false
                }
            }
            // Keyword match against title/value/desc/placeholder.
            let texts = [AXUtilities.title(el),
                         AXUtilities.value(el),
                         AXUtilities.desc(el),
                         AXUtilities.placeholder(el)].compactMap { $0 }
            let lowerKeywords = pattern.keywords.map { $0.lowercased() }
            for text in texts {
                let lower = text.lowercased()
                for kw in lowerKeywords {
                    switch pattern.matchMode {
                    case .exact:
                        if lower == kw { return true }
                    case .contains:
                        if lower.contains(kw) { return true }
                    }
                }
            }
            return false
        }
        return matches.first
    }

    /// Finds a short text snippet that looks like a working-time indicator.
    ///
    /// Unlike a plain keyword search, this enforces a per-attribute length cap
    /// (`maxWorkingIndicatorLength`). Real working indicators are short status
    /// labels ("已工作 3m 20s", "正在生成…", "Thinking"); long attribute strings
    /// are conversation messages or draft text that merely quote a keyword, and
    /// must NOT be treated as indicators. Each attribute is checked on its own
    /// (never joined), so a long draft that happens to contain "已工作" is skipped
    /// while a short status label is returned.
    ///
    /// Role filtering still applies: when a workingSignals pattern lists roles,
    /// only those roles are considered.
    static func findWorkingIndicatorText(definition: AppDefinition,
                                         in window: AXUIElement) -> String? {
        // 1. The app's own workingSignals patterns, with short-text enforcement
        //    and prefix-anchoring so conversation text quoting a keyword can't
        //    masquerade as a status indicator.
        for pattern in definition.rule.workingSignals {
            if let (text, role) = firstShortMatch(pattern, in: window, requirePrefix: true) {
                Logger.shared.logDebug("SignalDetector[\(definition.id)]: indicator hit role=\(role) text=\(text)")
                return text
            }
        }
        // 2. Common "Thinking" indicator fallback (short text + prefix only).
        if let (text, role) = firstShortMatch(
            SignalPattern(keywords: ["Thinking"], roles: [], matchMode: .contains),
            in: window,
            requirePrefix: true
        ) {
            Logger.shared.logDebug("SignalDetector[\(definition.id)]: indicator hit (thinking) role=\(role) text=\(text)")
            return text
        }
        return nil
    }

    /// Searches the window for the first element where a *single* attribute
    /// (title/value/desc/placeholder) both matches the pattern's keywords and
    /// fits within `maxWorkingIndicatorLength`. Returns `(text, role)` of the
    /// matched element, or nil. Role and contextFilter constraints from the
    /// pattern are honored.
    ///
    /// Traversal stops at the first matching element (DFS order), so even when
    /// the pattern's roles are empty it does not materialize the whole tree.
    private static func firstShortMatch(_ pattern: SignalPattern,
                                        in window: AXUIElement?,
                                        requirePrefix: Bool = false) -> (text: String, role: String)? {
        guard let window = window else { return nil }

        let buttonRoles: Set<String> = [
            "AXButton", "AXPopUpButton", "AXCheckBox",
            "AXMenuBarItem", "AXMenuItem", "AXMenuButton", "AXToolbarItem"
        ]
        let lowerKeywords = pattern.keywords.map { $0.lowercased() }

        // Find the first element (DFS order) whose single short attribute
        // matches. searchFirst stops at the first match instead of walking the
        // whole tree, which matters because workingSignals roles are often empty.
        guard let el = AXUtilities.searchFirst(window, maxDepth: 25, predicate: { el in
            if pattern.contextFilter == .buttonOnly {
                guard let r = AXUtilities.role(el), buttonRoles.contains(r) else {
                    return false
                }
            }
            if !pattern.roles.isEmpty {
                guard let r = AXUtilities.role(el), pattern.roles.contains(r) else {
                    return false
                }
            }
            return Self.shortAttribute(of: el, keywords: lowerKeywords,
                                       matchMode: pattern.matchMode,
                                       requirePrefix: requirePrefix) != nil
        }) else {
            return nil
        }
        guard let text = Self.shortAttribute(of: el, keywords: lowerKeywords,
                                             matchMode: pattern.matchMode,
                                             requirePrefix: requirePrefix) else {
            return nil
        }
        let role = AXUtilities.role(el) ?? "unknown"
        return (text: text, role: role)
    }

    /// Returns the first short attribute (title/value/desc/placeholder) of `el`
    /// that both fits `maxWorkingIndicatorLength` and matches one of the given
    /// lowercased keywords under `matchMode`. nil otherwise.
    ///
    /// When `requirePrefix` is true, the keyword must appear at the START of the
    /// attribute text (case-insensitive). This is used for working indicators:
    /// real status labels begin with the status word ("已工作 3m", "正在生成…",
    /// "Thinking"), whereas conversation messages only quote the word mid-sentence
    /// ("…的工作信号里没有'Loading'…"). Prefix-anchoring cleanly separates the two.
    private static func shortAttribute(of el: AXUIElement,
                                       keywords lowerKeywords: [String],
                                       matchMode: MatchMode,
                                       requirePrefix: Bool = false) -> String? {
        let attrs = [AXUtilities.title(el),
                     AXUtilities.value(el),
                     AXUtilities.desc(el),
                     AXUtilities.placeholder(el)].compactMap { $0 }
        for text in attrs {
            guard text.count <= maxWorkingIndicatorLength else { continue }
            let lower = text.lowercased()
            for kw in lowerKeywords {
                switch matchMode {
                case .exact:
                    if lower == kw { return text }
                case .contains:
                    if requirePrefix {
                        if lower.hasPrefix(kw) { return text }
                    } else {
                        if lower.contains(kw) { return text }
                    }
                }
            }
        }
        return nil
    }

    /// Builds a short human-readable snippet for an AX element.
    static func snippet(of el: AXUIElement) -> String {
        var parts: [String] = []
        if let r = AXUtilities.role(el) { parts.append("role=\(r)") }
        if let t = AXUtilities.title(el) { parts.append("title=\(t)") }
        if let v = AXUtilities.value(el) { parts.append("value=\(v)") }
        if let d = AXUtilities.desc(el) { parts.append("desc=\(d)") }
        return parts.joined(separator: " ")
    }
}
