import Foundation

/// Read-only live smoke test. It never starts, clicks, or types into an agent;
/// it captures the current on-screen window and runs the production OCR rule.
/// A live task is optional, so a missing app/window is reported as SKIP rather
/// than making a developer's machine fail the whole regression suite.
@main
struct LiveSceneSmokeMain {
    static func main() {
        let targetIDs = ["workbuddy", "zcode", "chatgpt"]
        let definitions = Dictionary(uniqueKeysWithValues: watchedApps.map { ($0.id, $0) })
        var failures = 0
        var passes = 0
        var unknowns = 0
        var skips = 0

        print("── Live scene smoke: WorkBuddy / Z Code / ChatGPT ──")
        for appID in targetIDs {
            guard let definition = definitions[appID],
                  let rule = definition.rule.ocrRule else {
                print("  ⏭️  SKIP \(appID): no OCR rule")
                skips += 1
                continue
            }

            guard let windowID = ScreenshotCapture.findWindowId(bundleId: definition.bundleId) else {
                print("  ⏭️  SKIP \(appID): app/window is not on screen")
                skips += 1
                continue
            }

            var result: VisionDetector.OCRResult?
            VisionDetector.detect(bundleId: definition.bundleId, rule: rule) {
                result = $0
            }
            let deadline = Date().addingTimeInterval(20)
            while result == nil && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }

            guard let result = result else {
                print("  ❌ \(appID): OCR timed out (window=\(windowID))")
                failures += 1
                continue
            }

            let preview = result.rawTexts.prefix(8).joined(separator: " | ")
            let confidence = String(format: "%.2f", result.confidence)
            let previewText = preview.isEmpty ? "<empty>" : preview
            if result.state == .unknown {
                print("  ⚠️  \(appID): window=\(windowID) state=unknown (capture succeeded; no active-state phrase in this frame)")
                unknowns += 1
            } else {
                print("  ✅ \(appID): window=\(windowID) state=\(result.state) conf=\(confidence) text=\(result.matchedText)")
                passes += 1
            }
            print("     OCR: \(previewText)")
        }

        print("\n════════ Live smoke: \(passes) PASS / \(unknowns) UNKNOWN / \(failures) FAIL / \(skips) SKIP ════════")
        exit(failures == 0 ? 0 : 1)
    }
}
