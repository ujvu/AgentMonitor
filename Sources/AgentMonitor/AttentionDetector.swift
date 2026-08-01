import Foundation

/// Text-understanding layer for attention (confirm/choose popover) detection.
///
/// Consumes an `OCRDocument` (lines + merged paragraphs) produced by
/// `VisionDetector` and returns an `AttentionVerdict` via a scoring mechanism —
/// NOT a naive keyword match.
///
/// ### Scoring (spec)
/// - **Strong keyword** (compound phrases only — 确认执行 / 允许执行 / 是否继续 /
///   继续执行 …): a single hit triggers immediately (score += 3, triggers).
/// - **Weak keyword** (请确认 / 需要确认 / 怎么继续 …): contributes score but
///   never triggers alone (score += 1).
/// - **Numbered list structure** (1. 2. 3. / 1) 2) / ①②③ / "- 选项"): ≥3
///   consecutive numbered lines is a strong popover signal (score += 2).
/// - **Position**: popovers usually float near the crop's upper-middle region;
///   lines in the top 2/3 add a small bonus (+0.5).
///
/// Trigger rule: a strong hit OR total score ≥ 4.
enum AttentionDetector {

    /// One verdict from the detector.
    struct AttentionVerdict {
        let triggered: Bool
        let score: Float
        /// The text (line or paragraph) that best explains the verdict.
        let matchedText: String
        /// Confidence of the strongest contributing line.
        let confidence: Float
    }

    // MARK: - Pattern constants (app-independent)

    /// Numbered-list prefixes, in priority order.
    private static let numberedPrefixPatterns: [String] = [
        #"^\s*(\d+)[\.、．]\s*"#,   // 1. 2. 1、2、
        #"^\s*(\d+)[\s\)]\s*"#,    // 1 2(空格) / 1) 2) —— 实际弹窗常见格式
        #"^\s*[①②③④⑤⑥⑦⑧⑨⑩]\s*"#, // ①②③
        #"^\s*[-–—]\s*"#           // - 选项
    ]

    /// Strong compound keywords (app-independent core; per-app extras come from
    /// `rule.attentionKeywords`). Single words like 确认/继续/允许 are BANNED —
    /// they appear in ordinary conversation constantly.
    private static let coreStrongKeywords: [String] = [
        "确认执行", "允许执行", "是否继续", "继续执行",
        "同意执行", "批准执行", "确认继续", "是否允许",
    ]

    // MARK: - Entry point

    /// Analyzes an OCR document for attention signals.
    static func detect(document: VisionDetector.OCRDocument,
                       rule: OCRRule) -> AttentionVerdict {
        var score: Float = 0
        var bestText = ""
        var bestConfidence: Float = 0
        var strongHit = false

        let strongKeywords = coreStrongKeywords + rule.attentionKeywords

        // --- Pass 1: strong keywords over merged paragraphs + raw lines ---
        // Paragraphs first: a title split across lines ("你希望" / "我怎么继续？")
        // is re-joined, so compound keywords match across the split.
        for para in document.paragraphTexts {
            if containsAnyKeyword(para, strongKeywords) {
                strongHit = true
                score += 3
                if bestText.isEmpty { bestText = para }
            }
        }
        for line in document.lines {
            if containsAnyKeyword(line.text, strongKeywords) {
                strongHit = true
                score += 3
                bestConfidence = max(bestConfidence, line.confidence)
                if bestText.isEmpty { bestText = line.text }
            }
        }

        // --- Pass 2: weak keywords (score only, never trigger alone) ---
        for para in document.paragraphTexts {
            if containsAnyKeyword(para, rule.attentionWeakKeywords) {
                score += 1
            }
        }

        // --- Pass 3: numbered-list structure (strong popover signal) ---
        let numberedCount = countNumberedLines(document.lines)
        if numberedCount >= 3 {
            score += 2
        } else if numberedCount == 2 {
            score += 1
        }

        // --- Pass 4: position bonus (popovers float upper-middle) ---
        let maxY = document.lines.map { $0.frame.maxY }.max() ?? 1
        if document.lines.contains(where: { $0.frame.midY < maxY * 2 / 3 }) {
            score += 0.5
        }

        // --- Trigger rule: strong hit OR total score ≥ 4 ---
        let triggered = strongHit || score >= 4
        return AttentionVerdict(triggered: triggered,
                                score: score,
                                matchedText: bestText,
                                confidence: bestConfidence)
    }

    // MARK: - Helpers

    private static func containsAnyKeyword(_ text: String, _ keywords: [String]) -> Bool {
        let lower = text.lowercased()
        // 直接 contains。
        if keywords.contains(where: { lower.contains($0.lowercased()) }) { return true }
        // 去空格后再 contains——合并段落里 OCR 行之间会插入空格
        // （"你希望 我怎么继续？"），复合关键词 "希望我怎么继续" 因此匹配不上。
        let compact = lower.replacingOccurrences(of: " ", with: "")
        return keywords.contains { compact.contains($0.lowercased()) }
    }

    /// Counts lines that look like numbered list items ("1. xxx", "1) xxx",
    /// "①② xxx", "- xxx").
    private static func countNumberedLines(_ lines: [VisionDetector.OCRLine]) -> Int {
        var count = 0
        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            for pattern in numberedPrefixPatterns {
                if trimmed.range(of: pattern, options: .regularExpression) != nil {
                    count += 1
                    break
                }
            }
        }
        return count
    }
}
