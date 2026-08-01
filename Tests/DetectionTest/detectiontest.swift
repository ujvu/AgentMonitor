import Foundation
import CoreGraphics

/// Repeatable OCR regression tests built from real UI phrases observed in the
/// three monitored desktop agents. The test bypasses WindowServer capture and
/// exercises the same VisionDetector classification path used in production.
@main
struct DetectionTestMain {
    static func main() {
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            let mark = condition ? "✅" : "❌"
            print("  \(mark) \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !condition { failures += 1 }
        }

        let definitions = Dictionary(uniqueKeysWithValues: watchedApps.map { ($0.id, $0) })
        let cropHeight: CGFloat = 1_000

        func document(_ samples: [(String, CGFloat)]) -> VisionDetector.OCRDocument {
            let lines = samples.map { text, midY in
                VisionDetector.OCRLine(
                    text: text,
                    frame: CGRect(x: 120, y: midY - 12, width: 500, height: 24),
                    confidence: 0.95)
            }
            return VisionDetector.OCRDocument(
                lines: lines,
                paragraphs: lines.map { [$0] })
        }

        func classify(appID: String,
                       samples: [(String, CGFloat)]) -> VisionDetector.OCRResult? {
            guard let rule = definitions[appID]?.rule.ocrRule else { return nil }
            return VisionDetector.classify(
                document: document(samples),
                cropHeight: cropHeight,
                rule: rule,
                bundleId: "fixture.\(appID)")
        }

        func state(_ result: VisionDetector.OCRResult?) -> VisionDetector.OCRState? {
            result?.state
        }

        let expectedCases: [(String, String, VisionDetector.OCRState, [(String, CGFloat)])] = [
            // WorkBuddy phrases observed in its left task/status rail.
            ("WorkBuddy working", "workbuddy", .working,
             [("生成回复中", 180), ("② 运行命令", 420)]),
            ("WorkBuddy attention", "workbuddy", .needsAttention,
             [("是否允许继续执行", 360)]),
            ("WorkBuddy completed", "workbuddy", .completed,
             [("任务完成", 900)]),

            // Z Code phrases observed in the bottom status/input strip.
            ("Z Code working", "zcode", .working,
             [("探索·执行中", 180), ("继续输入以排队后续修改", 240)]),
            ("Z Code attention", "zcode", .needsAttention,
             [("确认继续", 350)]),
            ("Z Code completed", "zcode", .completed,
             [("提出后续修改要求", 900)]),

            // ChatGPT Worker phrases captured from the live main window:
            // "已处理 1m 19s", "正在运行命令", and "第 1/5 步".
            ("ChatGPT Worker working", "chatgpt", .working,
             [("已处理 1m 19s", 130), ("正在运行命令", 360), ("第 1/5 步", 650)]),
            ("ChatGPT Worker attention", "chatgpt", .needsAttention,
             [("需要确认是否继续", 420)]),
            ("ChatGPT Worker completed", "chatgpt", .completed,
             [("已完成", 860)]),
        ]

        print("── OCR 真实场景回归：WorkBuddy / Z Code / ChatGPT Worker ──")
        for (name, appID, expected, samples) in expectedCases {
            let actual = state(classify(appID: appID, samples: samples))
            check(name, actual == expected, "expected=\(expected) actual=\(String(describing: actual))")
        }

        print("── 历史对话误报回归 ──")
        for appID in ["workbuddy", "zcode", "chatgpt"] {
            let actual = state(classify(
                appID: appID,
                samples: [("这段历史消息讨论过如何完成任务，稍后再继续，但不是当前状态", 360)]))
            check("\(appID) historical text does not become active", actual == .unknown,
                  "actual=\(String(describing: actual))")
        }

        let conversationalCompletionMention = classify(
            appID: "chatgpt",
            samples: [("刚刚正常弹出了 working 窗口，但是任务完成后没有弹出窗口", 850)])
        check("ChatGPT long conversation mention is not completed",
              state(conversationalCompletionMention) == .unknown,
              "actual=\(String(describing: state(conversationalCompletionMention)))")

        if let chatGPT = definitions["chatgpt"] {
            let completionEvent = StateEvent(
                appId: "chatgpt",
                old: .working,
                new: .completed,
                snapshot: .completed,
                reason: "fixture completion")
            let idleEvent = StateEvent(
                appId: "chatgpt",
                old: .completed,
                new: .idle,
                snapshot: .idle,
                reason: "fixture settled")
            let presentation = IslandPresentationEngine()
            let scene = presentation.present(
                stateEvent: completionEvent,
                app: chatGPT,
                previous: .working)
            check("ChatGPT completion maps to celebration", scene.mode == .celebration)

            // Replay the real event order: completion is emitted first, then
            // the watcher settles the durable snapshot to idle. This guards
            // the state-to-scene mapping; FloatingIsland separately keeps the
            // short-lived completion override visible over the idle event.
            let settledScene = presentation.present(
                stateEvent: idleEvent,
                app: chatGPT,
                previous: .completed)
            check("Completion replay settles to dormant", settledScene.mode == .dormant)
        }

        print("── 多智能体优先级回归 ──")
        let attention = IslandScene(
            mode: .attention, title: "WORKBUDDY", subtitle: "NEED ACTION",
            icon: "robot_attention", animation: .alert, priority: 40,
            appId: "workbuddy")
        let completion = IslandScene(
            mode: .celebration, title: "CHATGPT", subtitle: "DONE",
            icon: "robot_complete", animation: .complete, priority: 30,
            appId: "chatgpt")
        let working = IslandScene(
            mode: .active, title: "Z CODE", subtitle: "WORKING",
            icon: "robot_working", animation: .working, priority: 20,
            appId: "zcode")
        let orderedModes = [working, completion, attention]
            .sorted { $0.priority > $1.priority }
            .map(\.mode)
        check("Attention outranks completion and working",
              orderedModes == [.attention, .celebration, .active])
        check("All three scenes remain actionable",
              [attention, completion, working].allSatisfy(\.isActionable))

        print(failures == 0
              ? "\n════ 检测回归全部通过 ════"
              : "\n════ \(failures) 项检测回归失败 ════")
        exit(failures == 0 ? 0 : 1)
    }
}
