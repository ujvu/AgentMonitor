import Foundation
import CoreGraphics

// MARK: - MatchMode

/// How a keyword should be compared against element text.
enum MatchMode: String, Codable {
    /// The element text must exactly equal the keyword (case-insensitive).
    case exact
    /// The element text must contain the keyword (case-insensitive substring).
    case contains
}

// MARK: - OCRRule

/// Vision-OCR fallback rule for apps whose working state isn't exposed via
/// Accessibility (typical of Electron/canvas-rendered apps like Z Code).
///
/// When an app carries an `ocrRule`, AgentMonitor periodically screenshots the
/// configured window region, runs Vision text recognition, and uses matches as
/// supplementary evidence for the fusion engine. Apps without an `ocrRule`
/// (QwenWork, WorkBuddy, ChatGPT) keep their pure-AX behavior unchanged.
struct OCRRule: Equatable {
    /// Semantic name for the captured region (e.g. "bottomStatusBar"), for logs
    /// and future per-region routing.
    let regionName: String
    /// Normalized crop rectangle in window space. Origin (0,0) is top-left,
    /// width/height are fractions of the window. e.g. the bottom 25% is
    /// CGRect(x:0, y:0.75, width:1, height:0.25).
    let regionRatio: CGRect
    /// Words indicating the agent is actively working.
    let workingKeywords: [String]
    /// Words indicating the agent needs the user (continue/approve). Use
    /// compound phrases ("确认继续") rather than bare words ("继续") to avoid
    /// matching them inside ordinary conversation text.
    let attentionKeywords: [String]
    /// Weak attention words: contribute to the attention score but never
    /// trigger alone (请确认 / 需要确认 / 怎么继续 …). See AttentionDetector.
    let attentionWeakKeywords: [String]
    /// Words indicating the task is finished.
    let completedKeywords: [String]
    /// Minimum Vision confidence for a line to be considered a match (0...1).
    let minConfidence: Float
    /// How long an OCR hint stays valid before it's treated as stale (seconds).
    /// Without refresh within TTL, the OCR evidence reverts to nil so a stale
    /// conclusion can't pin the status. App-specific: fast apps 8s, slower ones
    /// may need 15s.
    let hintTTL: TimeInterval
    /// Y-fraction (top=0, bottom=1, in the cropped image) above which a
    /// workingKeyword hit is trusted. Without this filter, a keyword like
    /// "新建任务中" appearing inside the conversation body would falsely fire
    /// `working` while the user is just chatting. Default 0.30 = only trust
    /// hits in the top 30% of the crop (the toolbar / status pill area).
    let workingMaxYFraction: Float
    /// Y-fraction below which a completedKeyword hit is trusted. Default 0.70
    /// = only trust hits in the bottom 30% of the crop (where "已完成" pills
    /// appear near the input box).
    let completedMinYFraction: Float
    /// Confidence threshold for workingKeyword matches. Toolbar button text
    /// (the real indicator) typically scores 0.8-1.0; ordinary conversation
    /// text containing the same keyword usually scores ≤0.5. Combined with
    /// `workingMaxYFraction`, this double-filters false positives from the
    /// user typing the keyword inside a message.
    let workingMinConfidence: Float
    /// Confidence threshold for completedKeyword matches. Same rationale as
    /// `workingMinConfidence`.
    let completedMinConfidence: Float
    /// Maximum OCR line length accepted for a completed marker. Long lines are
    /// usually conversation text that merely mentions "完成"; real status
    /// pills/placeholders are short. `nil` keeps the legacy behavior.
    let completedMaxLineLength: Int?
    /// Compound activity patterns: each inner array is an AND-set of words
    /// that must ALL appear in the same OCR frame to count as one "activity
    /// hit". Used by AppWatcher's 6-second sliding window — accumulating
    /// enough activity hits promotes to `working` even when the working
    /// status banner itself is too transient to OCR. Default `[]` (disabled).
    ///
    /// IMPORTANT: do NOT add bare tool names (Bash / Read / Edit) here — the
    /// agent's own explanations of past tool use ("用 Edit 来插入 old_string")
    /// would then permanently count as activity. Use compound patterns that
    /// only fire on a *current* tool call (e.g. tool name + live argument
    /// token like `new_string`, `ls -la`).
    let workingActivityPatterns: [[String]]
    /// OCR poll cadence when the app is frontmost (seconds). Default 3.0.
    let foregroundInterval: TimeInterval
    /// OCR poll cadence when the app is backgrounded (seconds). Default 12.0.
    let backgroundInterval: TimeInterval

    init(regionName: String,
         regionRatio: CGRect,
         workingKeywords: [String],
         attentionKeywords: [String],
         completedKeywords: [String],
         minConfidence: Float = 0.8,
         hintTTL: TimeInterval = 8.0,
         workingMaxYFraction: Float = 0.30,
         completedMinYFraction: Float = 0.85,
         workingMinConfidence: Float = 0.8,
         completedMinConfidence: Float = 0.8,
         completedMaxLineLength: Int? = nil,
         attentionWeakKeywords: [String] = [],
         workingActivityPatterns: [[String]] = [],
         foregroundInterval: TimeInterval = 3.0,
         backgroundInterval: TimeInterval = 12.0) {
        self.regionName = regionName
        self.regionRatio = regionRatio
        self.workingKeywords = workingKeywords
        self.attentionKeywords = attentionKeywords
        self.completedKeywords = completedKeywords
        self.minConfidence = minConfidence
        self.hintTTL = hintTTL
        self.workingMaxYFraction = workingMaxYFraction
        self.completedMinYFraction = completedMinYFraction
        self.workingMinConfidence = workingMinConfidence
        self.completedMinConfidence = completedMinConfidence
        self.completedMaxLineLength = completedMaxLineLength
        self.attentionWeakKeywords = attentionWeakKeywords
        self.workingActivityPatterns = workingActivityPatterns
        self.foregroundInterval = foregroundInterval
        self.backgroundInterval = backgroundInterval
    }
}

// MARK: - ContextFilter

/// Optional filter to avoid matching signals in conversation history.
enum ContextFilter: String, Codable {
    /// Only match button-like elements (AXButton, AXPopUpButton, AXCheckBox,
    /// AXMenuItem, etc.). Prevents matching plain text inside conversation
    /// bubbles that happen to contain the keyword.
    case buttonOnly
    /// Match any element type (text, buttons, images, etc.).
    case anyElement
}

// MARK: - SignalPattern

/// A single detection pattern for an agent UI signal.
///
/// Combines keywords, AX role constraints, a match mode, and an optional
/// context filter to precisely identify UI elements that indicate agent state.
struct SignalPattern: Equatable {
    /// Text to match (case-insensitive).
    let keywords: [String]
    /// AX roles to match (e.g. "AXButton", "AXText"). Empty = any role.
    let roles: [String]
    /// How to compare keywords against element text.
    let matchMode: MatchMode
    /// Optional filter to avoid matching in conversation history.
    let contextFilter: ContextFilter?

    init(keywords: [String],
         roles: [String] = [],
         matchMode: MatchMode = .contains,
         contextFilter: ContextFilter? = nil) {
        self.keywords = keywords
        self.roles = roles
        self.matchMode = matchMode
        self.contextFilter = contextFilter
    }
}

// MARK: - AppRule

/// A set of detection rules for a single app, organized by signal type.
struct AppRule: Equatable {
    /// Patterns for "needs continue" — the agent paused and is waiting
    /// for the user to click a "继续"/"Continue" button.
    let continueSignals: [SignalPattern]
    /// Patterns for "needs approval" — the agent is asking for permission
    /// or confirmation (e.g. "允许"/"Approve"/"确认").
    let approvalSignals: [SignalPattern]
    /// Patterns for "is working" — the agent is actively processing a task
    /// (e.g. "已工作"/"Working for" with time indicators, or a stop button).
    let workingSignals: [SignalPattern]
    /// Patterns for "task completed" — the agent finished its task
    /// (e.g. "已完成"/"✅ 完成"/"Done").
    let completionSignals: [SignalPattern]
    /// Patterns for the stop button — when present, indicates the agent
    /// is working; when it disappears, the task is done.
    let stopSignals: [SignalPattern]
    /// Patterns for the send button — used to track enabled/disabled
    /// transitions. Empty array means this app has no send button.
    let sendButtonSignals: [SignalPattern]
    /// Optional Vision-OCR fallback for apps that don't expose working state
    /// via Accessibility (Electron/canvas apps). nil = pure-AX behavior.
    let ocrRule: OCRRule?

    init(continueSignals: [SignalPattern] = [],
         approvalSignals: [SignalPattern] = [],
         workingSignals: [SignalPattern] = [],
         completionSignals: [SignalPattern] = [],
         stopSignals: [SignalPattern] = [],
         sendButtonSignals: [SignalPattern] = [],
         ocrRule: OCRRule? = nil) {
        self.continueSignals = continueSignals
        self.approvalSignals = approvalSignals
        self.workingSignals = workingSignals
        self.completionSignals = completionSignals
        self.stopSignals = stopSignals
        self.sendButtonSignals = sendButtonSignals
        self.ocrRule = ocrRule
    }
}

// MARK: - AppDefinition

/// Defines a watched AI agent desktop app and its detection rules.
struct AppDefinition: Identifiable, Equatable {
    let id: String
    let displayName: String
    let bundleId: String
    let processName: String
    let rule: AppRule

    init(id: String,
         displayName: String,
         bundleId: String,
         processName: String,
<<<<<<< HEAD
=======
         enabled: Bool = true,
>>>>>>> d6ed8c9 (feat(ui): keep disabled apps out of floating island rotation & menu)
         rule: AppRule) {
        self.id = id
        self.displayName = displayName
        self.bundleId = bundleId
        self.processName = processName
        self.enabled = enabled
        self.rule = rule
    }

    // MARK: - Backward-Compat Computed Properties
    //
    // These flatten the SignalPattern arrays into simple keyword arrays
    // so that existing code (SignalDetector, AppWatcher, StatusPanel) can
    // continue using flat `.continueKeywords` etc. without modification.

    var continueKeywords: [String] {
        rule.continueSignals.flatMap { $0.keywords }
    }
    var approvalKeywords: [String] {
        rule.approvalSignals.flatMap { $0.keywords }
    }
    var workingIndicatorPatterns: [String] {
        rule.workingSignals.flatMap { $0.keywords }
    }
    var completionKeywords: [String] {
        rule.completionSignals.flatMap { $0.keywords }
    }
    var stopButtonKeywords: [String] {
        rule.stopSignals.flatMap { $0.keywords }
    }
    var sendButtonKeywords: [String] {
        rule.sendButtonSignals.flatMap { $0.keywords }
    }
}

// MARK: - Watched Apps

/// All watched agent apps. Currently 4 apps are monitored:
/// QwenWork, WorkBuddy, ZCode, and ChatGPT.
let watchedApps: [AppDefinition] = [

    // 1. 千问办公 (QwenWork)
    AppDefinition(
        id: "qwenwork",
        displayName: "千问办公",
        bundleId: "cn.qwenwork.desktop.mac",
        processName: "QwenWorkCN",
        rule: AppRule(
            // Continue: "继续"/"Continue" as button, exact match, buttonOnly
            continueSignals: [
                SignalPattern(
                    keywords: ["继续", "Continue"],
                    roles: ["AXButton", "AXPopUpButton", "AXCheckBox",
                            "AXMenuItem", "AXMenuBarItem", "AXToolbarItem"],
                    matchMode: .exact,
                    contextFilter: .buttonOnly
                ),
            ],
            // Approval: buttons with approval text
            approvalSignals: [
                SignalPattern(
                    keywords: ["允许", "Approve", "Allow", "确认", "确定",
                               "立刻发送", "同意执行", "授权"],
                    roles: ["AXButton", "AXPopUpButton", "AXCheckBox",
                            "AXMenuItem", "AXMenuBarItem", "AXToolbarItem"],
                    matchMode: .contains,
                    contextFilter: .buttonOnly
                ),
            ],
            // Working: specific Chinese status text that only appears during active processing.
            // Do NOT use "Loading" — it matches an AXGroup framework element that's always present.
            workingSignals: [
                SignalPattern(
                    keywords: ["已工作", "Working for", "正在生成命令", "正在生成", "生成中", "正在思考", "Thinking", "处理中"],
                    roles: [],
                    matchMode: .contains,
                    contextFilter: .anyElement
                ),
            ],
            // Completion: "已完成"/"✅ 完成"/"完成总结"/"Done"/"Finished" as any element
            completionSignals: [
                SignalPattern(
                    keywords: ["已完成", "✅ 完成", "完成总结", "Done", "Finished"],
                    roles: [],
                    matchMode: .contains,
                    contextFilter: .anyElement
                ),
            ],
            // Stop button: "停止"/"Stop"
            stopSignals: [
                SignalPattern(
                    keywords: ["停止", "Stop"],
                    roles: ["AXButton", "AXPopUpButton", "AXCheckBox",
                            "AXMenuItem", "AXMenuBarItem", "AXToolbarItem"],
                    matchMode: .contains,
                    contextFilter: .buttonOnly
                ),
            ],
            // Send button: QwenWork uses a send button, track enabled/disabled
            sendButtonSignals: [
                SignalPattern(
                    keywords: ["发送", "Send"],
                    roles: ["AXButton", "AXPopUpButton", "AXToolbarItem"],
                    matchMode: .contains,
                    contextFilter: .buttonOnly
                ),
            ],
            // OCR fallback: QwenWorkCN is an Electron app — its web content is
            // invisible to AX, so AX alone never sees the working state. Vision
            // OCR reads the lower half of the conversation where Qwen shows
            // "正在生成" / "思考中" while the agent is actively working.
            ocrRule: OCRRule(
                regionName: "chatLower",
                regionRatio: CGRect(x: 0, y: 0.5, width: 1.0, height: 0.5),
                workingKeywords: ["正在生成", "生成中", "思考中", "正在思考", "处理中",
                                  "推理中", "停止", "Stop", "中断"],
                attentionKeywords: ["是否继续", "确认执行", "允许执行", "同意执行",
                                    "继续执行", "需要确认", "想要执行", "请求访问",
                                    "需要授权", "拒绝"],
                // completed 误触发修复:去掉宽泛的「已完成」「完成」——
                // 千问办公执行中会显示「已完成N个步骤」(进行中反馈,任务
                // 还在跑),对话正文也常含"完成"子串(如"未完成提醒")。
                // 「输入/调用技能」是完成态输入框 placeholder(conf 1.00,
                // 类似 zcode 的「提出后续修改要求」),completed 优先级高于
                // working,可覆盖对话残留的「正在思考」。
                completedKeywords: ["全部完成", "任务完成", "执行完成",
                                    "Done", "Finished", "输入/调用技能"],
                minConfidence: 0.2,
                hintTTL: 10.0,
                // Vision 对中文小字识别置信度普遍 0.3~0.6(日志实测「正在生成
                // 命令」「处理中」= 0.30),默认 0.8 会全部过滤 → VERDICT=unknown。
                // 显式降低阈值 + 放宽 y 位置(状态胶囊在 crop 中下部,默认
                // workingMaxYFraction 0.30 会误拒)。
                workingMaxYFraction: 0.7,
                // This rule crops the bottom 25% of the window. The completed
                // input placeholder is near the top of that crop (roughly
                // 0.25 locally), not near the bottom of the full window.
                completedMinYFraction: 0.10,
                workingMinConfidence: 0.3,
                completedMinConfidence: 0.5,
                attentionWeakKeywords: ["请确认", "是否", "允许", "希望我",
                                        "怎么继续", "请选择"]
            )
        )
    ),

    // 2. WorkBuddy
    AppDefinition(
        id: "workbuddy",
        displayName: "WorkBuddy",
        bundleId: "com.workbuddy.workbuddy",
        processName: "Electron",
        rule: AppRule(
            // Continue: "继续"/"Continue" as button, exact
            continueSignals: [
                SignalPattern(
                    keywords: ["继续", "Continue"],
                    roles: ["AXButton", "AXPopUpButton", "AXCheckBox",
                            "AXMenuItem", "AXMenuBarItem", "AXToolbarItem"],
                    matchMode: .exact,
                    contextFilter: .buttonOnly
                ),
            ],
            // Approval: buttons with approval text
            // 「确认」「确定」已移除——WorkBuddy 界面有常驻按钮「运行 日志
            // 确认」(title 含「确认」),AX contains 匹配导致每次 poll 都误报
            // needsApproval,状态永久 needsAttention。授权弹窗特征词保留。
            approvalSignals: [
                SignalPattern(
                    keywords: ["允许", "Approve", "Allow",
                               "同意执行", "授权"],
                    roles: ["AXButton", "AXPopUpButton", "AXCheckBox",
                            "AXMenuItem", "AXMenuBarItem", "AXToolbarItem"],
                    matchMode: .contains,
                    contextFilter: .buttonOnly
                ),
            ],
            // Working: "已工作"/"Working for" containing with time words.
            // NO "新建任务中" — it's a static sidebar label, not a working indicator.
            workingSignals: [
                SignalPattern(
                    keywords: ["已工作", "Working for"],
                    roles: [],
                    matchMode: .contains,
                    contextFilter: .anyElement
                ),
            ],
            // Completion: "已完成"/"Done"/"Finished" as any element
            completionSignals: [
                SignalPattern(
                    keywords: ["已完成", "✅ 完成", "完成总结", "Done", "Finished"],
                    roles: [],
                    matchMode: .contains,
                    contextFilter: .anyElement
                ),
            ],
            // Stop button: WorkBuddy has a stop button while working
            stopSignals: [
                SignalPattern(
                    keywords: ["停止", "Stop"],
                    roles: ["AXButton", "AXPopUpButton", "AXCheckBox",
                            "AXMenuItem", "AXMenuBarItem", "AXToolbarItem"],
                    matchMode: .contains,
                    contextFilter: .buttonOnly
                ),
            ],
            // Send button: NONE — WorkBuddy uses a text input area, not a send button.
            sendButtonSignals: [],
            // OCR fallback: WorkBuddy is an Electron app — its Accessibility
            // tree is empty (AXWindow > AXWebArea, no children), so AX alone
            // never sees the working state. Vision OCR reads the conversation
            // tail above the input box where WorkBuddy shows "正在执行命令" /
            // "已消耗" while the agent is actively working.
            // Region broadened to cover the entire right pane + top toolbar
            // (the "新建任务中" status pill sits at the top of the pane, not in
            // the conversation body). y: 0.10..1.00 catches both the top
            // indicator and any bottom-band spinner.
            ocrRule: OCRRule(
                // 布局实测(2026-08-01 全窗口 OCR):WorkBuddy 是「左侧聊天/工具
                // 状态列(x≈0.05-0.28)+ 右侧工作区」布局。所有工作信号都在左侧:
                // 「生成回复中」(x=0.15)、「② 运行命令」(x=0.13)、「深度思考」
                // (x=0.11)、「已读取 SKILL.md」(x=0.16)、「开始编辑《…》」(x=0.15)。
                // 原 region x 从 0.28 开始 → 左侧列被整个裁掉,历次漏检的根源。
                // 扩展到全宽覆盖左侧列;右侧工作区(如内嵌网页)无关键词噪音。
                regionName: "conversationTail",
                regionRatio: CGRect(x: 0.02, y: 0.05, width: 0.98, height: 0.95),
                // Real working indicators observed via OCR (high-confidence):
                //   - "新建任务中"     (top toolbar pill, ~1.0 conf)
                //   - "生成回复中"     (mid-conversation, ~1.0 conf)
                //   - "想法预热中"     (thinking spinner)
                //   - "努力转动中"     (spinner alt)
                //   - "正在生成"       (status banner)
                //   - "已消耗"         (token meter chip)
                //   - "稍等，我去把答案捞回来" (catchphrase)
                //   - "我在沉思"     (deep-think status banner, OCR 实测 conf 1.00)
                //   - "深度思考"     (left rail status, OCR 实测 conf 1.00)
                // 第一轮标定新增(2026-08-01):覆盖多模型/多阶段状态文字
                //   - "正在思考"     (thinking spinner alt)
                //   - "思考中"       (truncated "正在思考" 情况)
                //   - "正在写入"     (写文件时)
                //   - "正在写入文件" (写文件时,详细描述)
                // 第二轮标定补词(2026-08-01,OCR 实测 conf 1.00):
                //   - "已读不回"     (任务执行期横幅 "Buddy 已读不回是因为在干活",
                //                     完整文案含名字前缀 OCR 常截断,子串匹配够用)
                workingKeywords: ["新建任务中", "生成回复中", "想法预热中",
                                  "努力转动中", "正在生成", "正在执行命令",
                                  "已消耗", "稍等，我去把答案捞回来",
                                  "执行中", "运行命令", "沉思",
                                  "我在沉思", "正在思考", "思考中",
                                  "正在写入", "正在写入文件",
                                  "深度思考", "已读不回"],
                attentionKeywords: ["是否允许", "确认执行", "等待用户确认",
                                    "等待您的回答", "希望我怎么继续",
                                    "同意执行", "是否继续"],
                completedKeywords: ["任务完成", "Done", "Finished", "✅ 完成"],
                minConfidence: 0.2,
                hintTTL: 10.0,
                // Vision 默认 workingMinConfidence=0.8 + workingMaxYFraction=0.30
                // 会拒掉「我在沉思」(conf 1.00 没问题但 y 在 85%)和
                // 「L，我在沉思」(conf 0.50 < 0.8)。显式放宽到 0.3 / 0.95
                // 覆盖 WorkBuddy 状态文字位置(对话区中下部)。
                workingMaxYFraction: 0.95,
                completedMinYFraction: 0.85,
                workingMinConfidence: 0.3,
                completedMinConfidence: 0.5,
                attentionWeakKeywords: ["需要确认", "请确认", "待确认",
                                        "希望怎么继续", "你想怎么", "怎么继续",
                                        "请选择", "请输入"],
                // 第二轮标定(2026-08-01):复合活动模式 — 在同一 OCR 帧内全部词
                // 同时出现才算一次"活动命中"。由 AppWatcher 在 6 秒滑动窗口
                // 内累加 → 累加够多时升级为 working(弥补状态横幅瞬态漏抓)。
                // 必须用"工具名 + 实时参数"组合,避免对历史工具说明的旧回复
                // 误命中(那种回复只含工具名不含 `new_string` 等实时 token)。
                // 注意:此字段在 init 参数中位于 attentionWeakKeywords 之后。
                workingActivityPatterns: [
                    ["old_string", "new_string"],   // Edit 工具同帧出现
                    ["用 Edit", "插入"],            // Edit 工具说明
                    ["Edit", "new_string"],         // Edit 工具 + 实时参数
                    ["Bash", "ls -la"],             // Bash + 列出命令
                    ["Bash", "python3"],            // Bash + 解释器
                    ["正在执行", "命令"]             // 状态横幅变体
                ],
                // 第二轮标定(2026-08-01):更密的 OCR 抓取,弥补状态横幅
                // 2-3 秒瞬态漏抓(默认 3.0s/12.0s)。其他 app 用默认。
                foregroundInterval: 1.0,
                backgroundInterval: 5.0
            )
        )
    ),

    // 3. Z Code
    AppDefinition(
        id: "zcode",
        displayName: "Z Code",
        bundleId: "dev.zcode.app",
        processName: "ZCode",
        rule: AppRule(
            // Continue: "继续"/"Continue" as button or short text, exact match
            continueSignals: [
                SignalPattern(
                    keywords: ["继续", "Continue"],
                    roles: ["AXButton", "AXPopUpButton", "AXCheckBox",
                            "AXMenuItem", "AXMenuBarItem", "AXToolbarItem"],
                    matchMode: .exact,
                    contextFilter: .buttonOnly
                ),
                // Also allow short text elements (e.g. a link or static text)
                SignalPattern(
                    keywords: ["继续", "Continue"],
                    roles: ["AXStaticText", "AXText", "AXLink"],
                    matchMode: .exact,
                    contextFilter: .anyElement
                ),
            ],
            // Approval: "Approve"/"Allow"/"允许"/"同意"/"Accept"/"确认"/"确定" as buttons
            approvalSignals: [
                SignalPattern(
                    keywords: ["Approve", "Allow", "允许", "同意", "Accept",
                               "确认", "确定"],
                    roles: ["AXButton", "AXPopUpButton", "AXCheckBox",
                            "AXMenuItem", "AXMenuBarItem", "AXToolbarItem"],
                    matchMode: .contains,
                    contextFilter: .buttonOnly
                ),
            ],
            // Working: "已工作"/"Working for"/"Loading" etc.
            workingSignals: [
                SignalPattern(
                    keywords: ["已工作", "Working for", "Loading", "正在生成", "生成中", "正在思考", "Thinking"],
                    roles: [],
                    matchMode: .contains,
                    contextFilter: .anyElement
                ),
            ],
            // Completion: "✅ 完成"/"完成总结"/"Done"/"Finished"/"已完成" as any element
            completionSignals: [
                SignalPattern(
                    keywords: ["✅ 完成", "完成总结", "Done", "Finished", "已完成"],
                    roles: [],
                    matchMode: .contains,
                    contextFilter: .anyElement
                ),
            ],
            // Stop button: "停止"/"Stop"/"中断"
            stopSignals: [
                SignalPattern(
                    keywords: ["停止", "Stop", "中断"],
                    roles: ["AXButton", "AXPopUpButton", "AXCheckBox",
                            "AXMenuItem", "AXMenuBarItem", "AXToolbarItem"],
                    matchMode: .contains,
                    contextFilter: .buttonOnly
                ),
            ],
            // Send button: "发送"/"Send" as button, track enabled/disabled
            sendButtonSignals: [
                SignalPattern(
                    keywords: ["发送", "Send"],
                    roles: ["AXButton", "AXPopUpButton", "AXToolbarItem"],
                    matchMode: .contains,
                    contextFilter: .buttonOnly
                ),
            ],
            // OCR fallback: Z Code (Electron/VSCode kernel) renders its chat and
            // status bar in a canvas layer that Accessibility cannot read, so AX
            // alone never sees working/attention/completion. Vision OCR reads the
            // bottom status strip where Z Code shows "探索·执行中" / the input
            // placeholder "继续输入以排队后续修改". Attention/completed keywords are
            // conservative compound phrases — refine from OCRDebug logs later.
            ocrRule: OCRRule(
                regionName: "bottomStatusBar",
                regionRatio: CGRect(x: 0, y: 0.75, width: 1.0, height: 0.25),
                // "继续输入以排队后续修改" — 用「排队后续」而非「继续输入以排队」,
                // 因为 Vision 偶尔把「继」误识为「陛」(conf 0.50),导致整词失配。
                // 「排队后续」字符稳定可识别,且语义唯一(仅 working 态出现)。
                workingKeywords: ["执行中", "探索中", "排队后续", "规划中", "思考中",
                                  "输入以排队"],
                attentionKeywords: ["确认继续", "批准执行", "允许执行", "同意继续",
                                    "继续执行", "是否继续"],
                completedKeywords: ["已完成", "任务完成", "已结束", "Done", "Finished",
                                    "提出后续修改要求"],
                minConfidence: 0.45,
                hintTTL: 8.0,
                workingMaxYFraction: 0.30,
                // The completed input placeholder sits near the top of this
                // bottom-quarter crop, not near the bottom of the full window.
                completedMinYFraction: 0.10,
                workingMinConfidence: 0.45,
                completedMinConfidence: 0.45,
                attentionWeakKeywords: ["需要确认", "请确认", "怎么继续"]
            )
        )
    ),

    // 4. ChatGPT Desktop (bundle ID is com.openai.codex, executable is ChatGPT)
    AppDefinition(
        id: "chatgpt",
        displayName: "ChatGPT",
        bundleId: "com.openai.codex",
        processName: "ChatGPT",
        rule: AppRule(
            continueSignals: [
                SignalPattern(
                    keywords: ["Continue", "继续", "Continue generating"],
                    roles: ["AXButton", "AXPopUpButton", "AXCheckBox",
                            "AXMenuItem", "AXMenuBarItem", "AXToolbarItem"],
                    matchMode: .exact,
                    contextFilter: .buttonOnly
                ),
            ],
            approvalSignals: [
                SignalPattern(
                    keywords: ["Approve", "Allow", "同意", "Accept", "确认", "确定"],
                    roles: ["AXButton", "AXPopUpButton", "AXCheckBox",
                            "AXMenuItem", "AXMenuBarItem", "AXToolbarItem"],
                    matchMode: .contains,
                    contextFilter: .buttonOnly
                ),
            ],
            workingSignals: [
                SignalPattern(
                    keywords: ["Working for", "已工作", "Thinking", "Loading", "正在生成", "生成中"],
                    roles: [],
                    matchMode: .contains,
                    contextFilter: .anyElement
                ),
            ],
            completionSignals: [
                SignalPattern(
                    keywords: ["Done", "Finished", "完成", "已完成"],
                    roles: [],
                    matchMode: .contains,
                    contextFilter: .anyElement
                ),
            ],
            stopSignals: [
                SignalPattern(
                    keywords: ["Stop", "停止", "中断"],
                    roles: ["AXButton", "AXPopUpButton", "AXCheckBox",
                            "AXMenuItem", "AXMenuBarItem", "AXToolbarItem"],
                    matchMode: .contains,
                    contextFilter: .buttonOnly
                ),
            ],
            sendButtonSignals: [
                SignalPattern(
                    keywords: ["Send", "发送"],
                    roles: ["AXButton", "AXPopUpButton", "AXToolbarItem"],
                    matchMode: .contains,
                    contextFilter: .buttonOnly
                ),
            ],
            // OCR fallback: ChatGPT Desktop Worker mode. The Worker surface is
            // different from normal Chat mode: the main window shows a runtime
            // line ("已处理 1m 6s"), a live tool row ("正在运行命令"), and a
            // progress chip ("第 1/5 步"). The status line is above the lower
            // half, so the old chatLower crop missed the most useful evidence.
            // Keep the crop wide and start near the top of the conversation
            // body; ScreenshotCapture selects the largest ChatGPT window so
            // mascot/pet overlay windows do not become the OCR source.
            ocrRule: OCRRule(
                regionName: "workerMain",
                regionRatio: CGRect(x: 0.02, y: 0.08, width: 0.96, height: 0.90),
                workingKeywords: ["正在运行命令", "运行命令", "正在运行", "已运行命令",
                                  "运行了命令", "已处理", "Verifying current OCR task status",
                                  "Verifying", "Investigating", "Generating", "Thinking",
                                  "正在验证", "验证中", "正在检查", "检查中", "正在生成",
                                  "生成中", "思考中", "处理中", "执行中", "工作中"],
                attentionKeywords: ["Need more info", "需要确认", "等待确认",
                                    "需要批准", "等待批准", "是否继续", "确认执行",
                                    "允许执行", "同意执行", "继续执行", "请选择",
                                    "Choose an option"],
                completedKeywords: ["Done", "Finished", "Completed", "已完成",
                                    "任务完成", "执行完成", "已结束"],
                minConfidence: 0.3,
                hintTTL: 10.0,
                workingMaxYFraction: 0.90,
                completedMinYFraction: 0.72,
                workingMinConfidence: 0.45,
                completedMinConfidence: 0.55,
                completedMaxLineLength: 24,
                attentionWeakKeywords: ["请确认", "等待您的回答", "希望我",
                                        "怎么继续", "需要我", "请输入"],
                // The progress chip is transient; these compound patterns
                // preserve a working lease even when Vision misses the status
                // row for one frame. They intentionally require a runtime
                // marker plus progress/tool text, not a bare "第" or "步骤".
                workingActivityPatterns: [
                    ["正在运行命令", "第"],
                    ["运行命令", "步"],
                    ["已处理", "第"],
                    ["正在运行", "已处理"],
                    ["已运行命令", "第"],
                    ["Verifying", "第"],
                    ["Investigating", "第"],
                    ["Working", "step"]
                ],
                foregroundInterval: 1.0,
                backgroundInterval: 5.0
            )
        )
    ),
]
