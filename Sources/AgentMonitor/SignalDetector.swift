import ApplicationServices
import Foundation

/// The type of attention signal detected from an agent app.
enum SignalType: String {
    case workingStarted     // 智能体开始工作
    case roundCompleted      // 一轮对话结束
    case needsContinue       // 出现"继续"按钮，需要点击
    case needsApproval       // 出现审批/允许按钮
    case needsChoice         // 出现选择/选项
    case workingStopped      // 工作计时器停止
    case completionIndicator // 出现完成标记
}

/// A detected signal representing an agent app needing the user's attention.
struct AttentionSignal: Equatable {
    let type: SignalType
    let reason: String          // Human-readable explanation
    let elementSnippet: String  // The text that triggered the detection

    static func == (lhs: AttentionSignal, rhs: AttentionSignal) -> Bool {
        lhs.type == rhs.type && lhs.elementSnippet == rhs.elementSnippet
    }
}

/// Per-app watcher state machine.
enum WatcherState: Equatable {
    case idle             // App running, ready for input
    case working          // Agent is actively processing a task
    case needsAttention   // Signal detected, notification shown
}

/// Detects "needs attention" signals from an app's Accessibility tree.
///
/// Different agent apps use different UI patterns:
/// - ZCode: "发送" button disabled when working, "已工作 X 秒" timer, "继续" text
/// - WorkBuddy: "新建任务中" text when working, "已完成 Xs" button when done, no send button
/// - ChatGPT: "Thinking..." text when working, stop button, "Continue generating"
/// - 千问办公: similar to ZCode patterns
///
/// The detector uses multiple strategies to cover all these patterns.
struct SignalDetector {

    // MARK: - Detection

    /// Analyzes an app's AX tree and returns the first detected signal, if any.
    /// Also updates the internal state used for transition tracking.
    static func detect(
        app: AXUIElement,
        definition: AppDefinition,
        state: inout WatcherState,
        lastSendEnabled: inout Bool?,
        lastTimerText: inout String?
    ) -> AttentionSignal? {

        guard let window = AXUtilities.focusedWindow(of: app) else { return nil }

        // 1. Check for "继续" / "Continue" — highest priority
        if let signal = checkContinueKeywords(window, definition) {
            state = .needsAttention
            return signal
        }

        // 2. Check for approval/permission buttons
        if let signal = checkApprovalKeywords(window, definition) {
            state = .needsAttention
            return signal
        }

        // 3. Check for NEW completion indicators (已完成, ✅完成, Done)
        if let signal = checkNewCompletionIndicators(window, definition, lastTimerText: &lastTimerText) {
            state = .needsAttention
            return signal
        }

        // 4. Check send button state transition (disabled → enabled)
        if let signal = checkSendButtonTransition(window, definition, state: &state, lastSendEnabled: &lastSendEnabled) {
            state = .needsAttention
            return signal
        }

        // 5. Check working timer — did it stop?
        if let signal = checkWorkingTimer(window, definition, state: &state, lastTimerText: &lastTimerText) {
            state = .needsAttention
            return signal
        }

        // No signal — update working state
        updateWorkingState(window, definition, state: &state, lastSendEnabled: &lastSendEnabled)

        return nil
    }

    // MARK: - Signal Checks

    /// Checks for "继续" / "Continue" buttons or text.
    private static func checkContinueKeywords(_ window: AXUIElement, _ def: AppDefinition) -> AttentionSignal? {
        let matches = AXUtilities.findElementsContaining(window, keywords: def.continueKeywords, maxDepth: 20)
        for match in matches {
            let role = AXUtilities.role(match) ?? ""
            if role.contains("Button") {
                let title = AXUtilities.title(match) ?? AXUtilities.desc(match) ?? AXUtilities.value(match) ?? ""
                if def.continueKeywords.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
                    return AttentionSignal(
                        type: .needsContinue,
                        reason: "智能体暂停，等待点击「\(title)」继续",
                        elementSnippet: title
                    )
                }
            }
        }
        for match in matches {
            let role = AXUtilities.role(match) ?? ""
            if role.contains("Text") || role.contains("Static") {
                let text = AXUtilities.title(match) ?? AXUtilities.value(match) ?? ""
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if def.continueKeywords.contains(where: { trimmed.caseInsensitiveCompare($0) == .orderedSame }) {
                    return AttentionSignal(
                        type: .needsContinue,
                        reason: "智能体暂停，等待点击「\(trimmed)」继续",
                        elementSnippet: trimmed
                    )
                }
            }
        }
        return nil
    }

    /// Checks for approval/confirmation/permission buttons.
    /// Matches buttons, pop-up buttons, and other interactive elements
    /// whose title, description, or value contains approval keywords.
    private static func checkApprovalKeywords(_ window: AXUIElement, _ def: AppDefinition) -> AttentionSignal? {
        let matches = AXUtilities.findElementsContaining(window, keywords: def.approvalKeywords, maxDepth: 20)
        for match in matches {
            let role = AXUtilities.role(match) ?? ""
            // Match buttons, pop-up buttons, and any clickable element
            if role.contains("Button") || role.contains("PopUp") || role.contains("MenuItem") {
                let text = AXUtilities.title(match) ?? AXUtilities.desc(match) ?? AXUtilities.value(match) ?? ""
                if def.approvalKeywords.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
                    return AttentionSignal(
                        type: .needsApproval,
                        reason: "需要确认：\(text)",
                        elementSnippet: text
                    )
                }
            }
        }
        return nil
    }

    /// Checks for NEW completion indicators that appeared since last poll.
    /// Searches ALL element types (buttons, text, headings) because different
    /// apps use different element types for completion markers:
    /// - WorkBuddy: "已完成 9m6s" as a button
    /// - ZCode: "✅ 完成总结" as a heading
    /// - ChatGPT: "Done" as text
    private static func checkNewCompletionIndicators(
        _ window: AXUIElement,
        _ def: AppDefinition,
        lastTimerText: inout String?
    ) -> AttentionSignal? {
        // Search for completion keywords in ALL element types
        let matches = AXUtilities.findElementsContaining(window, keywords: def.completionKeywords, maxDepth: 20)

        // Find the first completion text we haven't seen before
        for match in matches {
            let text = AXUtilities.title(match) ?? AXUtilities.value(match) ?? AXUtilities.desc(match) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if def.completionKeywords.contains(where: { trimmed.localizedCaseInsensitiveContains($0) }) {
                // Check if this is a new completion (not seen before)
                if trimmed != lastTimerText {
                    lastTimerText = trimmed
                    return AttentionSignal(
                        type: .completionIndicator,
                        reason: "任务完成：\(trimmed)",
                        elementSnippet: trimmed
                    )
                }
            }
        }
        return nil
    }

    /// Checks if the send button transitioned from disabled to enabled (round ended).
    private static func checkSendButtonTransition(
        _ window: AXUIElement,
        _ def: AppDefinition,
        state: inout WatcherState,
        lastSendEnabled: inout Bool?
    ) -> AttentionSignal? {
        let sendButtons = AXUtilities.searchTree(window, maxDepth: 20) { element, attrs in
            guard attrs["role"]!.contains("Button") else { return false }
            let combined = (attrs["title"]! + " " + attrs["desc"]! + " " + attrs["value"]!).lowercased()
            return def.sendButtonKeywords.contains { combined.contains($0.lowercased()) }
        }

        guard let sendButton = sendButtons.first else { return nil }
        let currentEnabled = AXUtilities.isEnabled(sendButton)

        defer { lastSendEnabled = currentEnabled }

        if let last = lastSendEnabled, last == false, currentEnabled == true {
            return AttentionSignal(
                type: .roundCompleted,
                reason: "一轮对话结束，可以输入新消息",
                elementSnippet: "发送按钮已激活"
            )
        }

        return nil
    }

    /// Checks if the working timer text stopped changing.
    /// Only fires if the text had CHANGED at least once before (to distinguish
    /// a real dynamic timer like "已工作 5秒"→"已工作 7秒" from static text
    /// like "新建任务中" that never changes).
    private static func checkWorkingTimer(
        _ window: AXUIElement,
        _ def: AppDefinition,
        state: inout WatcherState,
        lastTimerText: inout String?
    ) -> AttentionSignal? {
        // Only check for timer patterns that are actually dynamic timers
        // (containing time-related keywords), not static labels like "新建任务中"
        let timerKeywords = ["已工作", "Working for", "Thinking", "秒", "分", "minute", "second"]
        let matches = AXUtilities.findElementsContaining(window, keywords: timerKeywords, maxDepth: 20)
        guard let timerElement = matches.first else { return nil }

        let currentText = AXUtilities.title(timerElement) ?? AXUtilities.value(timerElement) ?? AXUtilities.desc(timerElement) ?? ""

        defer { lastTimerText = currentText }

        // Only fire "stopped" if the text was DIFFERENT last time (i.e., it was
        // actually changing like a real timer) and is now the same (stopped).
        // If the text was the same from the start, it's static text, not a timer.
        if let last = lastTimerText, last != currentText {
            // Text changed since last poll → still running, don't fire
            return nil
        }
        // We don't have enough info to know if this is a real timer that stopped
        // vs static text. This function is now effectively disabled for static text.
        // Timer-based detection is handled by the state transition in AppWatcher.
        return nil
    }

    // MARK: - Working State Detection

    /// Updates the watcher state using multiple signals:
    /// 1. Stop button present → working
    /// 2. Working indicator text present (新建任务中, 已工作, Thinking) → working
    /// 3. Send button disabled → working
    /// 4. Otherwise → idle
    private static func updateWorkingState(
        _ window: AXUIElement,
        _ def: AppDefinition,
        state: inout WatcherState,
        lastSendEnabled: inout Bool?
    ) {
        // 1. Check for stop button
        let stopButtons = AXUtilities.searchTree(window, maxDepth: 20) { element, attrs in
            guard attrs["role"]!.contains("Button") else { return false }
            let combined = (attrs["title"]! + " " + attrs["desc"]! + " " + attrs["value"]!).lowercased()
            return def.stopButtonKeywords.contains { combined.contains($0.lowercased()) }
        }
        if !stopButtons.isEmpty {
            state = .working
            lastSendEnabled = false
            return
        }

        // 2. Check for working indicator text (新建任务中, 已工作, Thinking, etc.)
        let workingMatches = AXUtilities.findElementsContaining(window, keywords: def.workingIndicatorPatterns, maxDepth: 20)
        if !workingMatches.isEmpty {
            state = .working
            lastSendEnabled = false
            return
        }

        // 3. Check send button state
        let sendButtons = AXUtilities.searchTree(window, maxDepth: 20) { element, attrs in
            guard attrs["role"]!.contains("Button") else { return false }
            let combined = (attrs["title"]! + " " + attrs["desc"]! + " " + attrs["value"]!).lowercased()
            return def.sendButtonKeywords.contains { combined.contains($0.lowercased()) }
        }

        if let sendButton = sendButtons.first {
            let currentEnabled = AXUtilities.isEnabled(sendButton)
            lastSendEnabled = currentEnabled
            state = currentEnabled ? .idle : .working
            return
        }

        // 4. No send button found — if we found completion indicators,
        //    the app is idle (running, ready for input). Otherwise leave as-is.
        let completionMatches = AXUtilities.findElementsContaining(window, keywords: def.completionKeywords, maxDepth: 20)
        if !completionMatches.isEmpty {
            // App has conversations but isn't processing → idle (ready)
            state = .idle
        }
        // If nothing found at all, leave state as-is
    }
}
