import Foundation

/// Defines a watched AI agent desktop app and its detection patterns.
struct AppDefinition: Identifiable, Equatable {
    let id: String
    let displayName: String
    let bundleId: String          // e.g. "cn.qwenwork.QwenWorkCN"
    let processName: String      // e.g. "QwenWorkCN" — for NSRunningApplication fallback

    /// Keywords that, when found in any AX element's title/value/description,
    /// signal the agent paused and is waiting for the user to click "继续".
    let continueKeywords: [String]

    /// Keywords for approval/permission buttons (e.g. "Approve", "允许").
    /// Also covers confirmation dialogs and queued-item prompts.
    let approvalKeywords: [String]

    /// Keywords for the "send" button — used to track enabled/disabled transitions.
    /// We match against an element's Description or Title.
    let sendButtonKeywords: [String]

    /// Keywords for the "stop" button — when present, the agent is working.
    /// When it disappears, the task is completed.
    let stopButtonKeywords: [String]

    /// Keywords for the "working" timer indicator (e.g. "已工作", "Working for").
    /// When this text stops changing, the agent finished its round.
    let workingIndicatorPatterns: [String]

    /// Keywords for completion indicators (e.g. "✅ 完成", "Done", "Finished").
    let completionKeywords: [String]
}

/// All watched apps. Extend this list to monitor more agent apps.
let watchedApps: [AppDefinition] = [
    AppDefinition(
        id: "qwenwork",
        displayName: "千问办公",
        bundleId: "cn.qwenwork.desktop.mac",
        processName: "QwenWorkCN",
        continueKeywords: ["继续", "Continue"],
        approvalKeywords: ["允许", "Approve", "Allow", "同意", "Accept", "确认", "确定", "立刻发送", "同意执行", "授权"],
        sendButtonKeywords: ["发送", "Send"],
        stopButtonKeywords: ["停止", "Stop", "中断", "Interrupt"],
        workingIndicatorPatterns: ["已工作", "Working for", "Thinking", "正在处理"],
        completionKeywords: ["✅ 完成", "完成总结", "Done", "Finished", "已完成"]
    ),
    AppDefinition(
        id: "workbuddy",
        displayName: "WorkBuddy",
        bundleId: "com.workbuddy.workbuddy",
        processName: "WorkBuddy",
        continueKeywords: ["继续", "Continue"],
        approvalKeywords: ["允许", "Approve", "Allow", "同意", "Accept", "确认", "确定", "同意执行", "授权"],
        sendButtonKeywords: ["发送", "Send"],
        stopButtonKeywords: ["停止", "Stop", "中断", "Interrupt"],
        workingIndicatorPatterns: ["已工作", "Working for", "Thinking", "正在处理"],
        completionKeywords: ["已完成", "✅ 完成", "完成总结", "Done", "Finished"]
    ),
    AppDefinition(
        id: "zcode",
        displayName: "Z Code",
        bundleId: "dev.zcode.app",
        processName: "ZCode",
        continueKeywords: ["继续", "Continue"],
        approvalKeywords: ["Approve", "Allow", "允许", "同意", "Accept", "确认", "确定", "同意执行", "授权"],
        sendButtonKeywords: ["发送", "Send"],
        stopButtonKeywords: ["停止", "Stop", "中断", "Interrupt"],
        workingIndicatorPatterns: ["已工作", "Working for", "Thinking", "正在处理"],
        completionKeywords: ["✅ 完成", "完成总结", "Done", "Finished", "已完成"]
    ),
    AppDefinition(
        id: "chatgpt",
        displayName: "ChatGPT",
        bundleId: "com.openai.codex",
        processName: "ChatGPT",
        continueKeywords: ["Continue", "继续", "Continue generating"],
        approvalKeywords: ["Approve", "Allow", "同意", "Accept", "确认", "确定", "同意执行", "授权"],
        sendButtonKeywords: ["Send", "发送"],
        stopButtonKeywords: ["Stop", "停止", "中断"],
        workingIndicatorPatterns: ["Working for", "已工作", "Thinking", "正在处理"],
        completionKeywords: ["Done", "Finished", "完成", "已完成"]
    ),
]
