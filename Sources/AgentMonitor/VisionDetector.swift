import Foundation
import Cocoa
import CoreGraphics
import Vision

/// Vision-OCR fallback detector for apps whose working state isn't reachable
/// via Accessibility (Electron/canvas apps). Periodically screenshots a window
/// region, runs on-device text recognition, and maps keyword hits to an
/// `OCRState` carrying the matched text + confidence.
///
/// This is purely an evidence source: it never touches the state machine. The
/// caller (`AppWatcher`) turns an `OCRResult` into `Evidence` and feeds the
/// fusion engine. All capture/OCR work runs on a background queue so the 2s
/// poll loop is never blocked.
enum VisionDetector {

    // MARK: - Types

    /// OCR-derived conclusion. Mirrors `AgentStatus` minus idle (OCR has no
    /// "idle" signal — absence of keywords means `unknown`, not idle).
    enum OCRState: Equatable {
        case unknown
        case working
        case needsAttention
        case completed
    }

    /// One OCR verdict. `confidence` is the highest among matching lines so the
    /// fusion engine sees the strongest signal, not the first.
    struct OCRResult: Equatable {
        let state: OCRState
        /// The matched line text (empty when state == .unknown).
        let matchedText: String
        /// Highest recognition confidence among the lines that matched a
        /// keyword for the winning state (0...1).
        let confidence: Float
        /// All recognized lines this run — for OCRDebug logging.
        let rawTexts: [String]
        /// Number of `workingActivityPatterns` (compound AND-sets) that
        /// matched the frame. `0` when none fired. VisionDetector does NOT
        /// promote `state` to .working from this signal alone — it's
        /// passed to `AppWatcher` which aggregates activity over a 6-second
        /// sliding window before promoting. Default `0` for compatibility.
        let activityScore: Int
        /// The actual activity patterns that hit in this frame (for logging
        /// and for AppWatcher to know which patterns are firing). Default `[]`.
        let matchedActivityPatterns: [[String]]
        /// Stable hash of the frame's text payload (joined `rawTexts`). Used
        /// by `AppWatcher` to detect "text is still changing" → keep the
        /// working lease alive even when no new keyword fires. Default `0`
        /// means "no previous frame seen yet".
        let textFingerprint: UInt64
    }

    /// One recognized text line with its full bounding box (in cropped-image
    /// pixel coordinates, top-left origin). Downstream analyzers (attention
    /// detection, paragraph merging) need the frame, not just the y-center.
    struct OCRLine: Equatable {
        let text: String
        /// Bounding box in the cropped image (top-left origin, pixels).
        let frame: CGRect
        let confidence: Float
    }

    /// The full OCR document: recognized lines + merged paragraphs.
    ///
    /// Paragraphs fix the "title split across lines" problem: a popover title
    /// like "你希望我怎么继续？" may be OCR'd as two lines; merging by y-distance
    /// + x-relationship + vertical continuity reconstructs the original text so
    /// keyword matching works across the split.
    struct OCRDocument: Equatable {
        let lines: [OCRLine]
        /// Merged paragraphs; each is an array of lines joined by y-order.
        let paragraphs: [[OCRLine]]
        /// Convenience: joined paragraph texts.
        var paragraphTexts: [String] {
            paragraphs.map { $0.map(\.text).joined(separator: " ") }
        }
    }

    // MARK: - Detection

    /// Capture `bundleId`'s window, crop to `rule.regionRatio`, OCR it, and map
    /// keyword matches to an `OCRResult`. `completion` is invoked on the main
    /// queue. Capture/OCR failures yield `.unknown` (never call back with an
    /// error) — a missing window is normal for backgrounded apps.
    static func detect(bundleId: String,
                       rule: OCRRule,
                       completion: @escaping (OCRResult) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = detectSync(bundleId: bundleId, rule: rule)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Synchronous core (background queue)

    /// Synchronous capture → crop → OCR → match. Runs on a background queue via
    /// `detect`. Returns `.unknown` on any capture failure.
    private static func detectSync(bundleId: String, rule: OCRRule) -> OCRResult {
        // 1. Capture the window.
        let capture = ScreenshotCapture.captureWindowImage(bundleId: bundleId)
        let cgImage: CGImage
        switch capture {
        case .success(let img):
            cgImage = img
        case .failure(let err):
            // noWindow is expected when the app is backgrounded/hidden — log at
            // debug to avoid noise. Other errors are more interesting.
            if err == .noWindow || err == .appNotRunning {
                Logger.shared.logDebug("VisionDetector[\(bundleId)]: skip — \(err)")
            } else {
                Logger.shared.logWarning("VisionDetector[\(bundleId)]: capture \(err)")
            }
            return OCRResult(state: .unknown, matchedText: "", confidence: 0,
                            rawTexts: [], activityScore: 0,
                            matchedActivityPatterns: [], textFingerprint: 0)
        }

        // 2. Crop to the configured region.
        guard let cropped = crop(image: cgImage, to: rule.regionRatio) else {
            Logger.shared.logWarning("VisionDetector[\(bundleId)]: crop failed (region=\(rule.regionRatio))")
            return OCRResult(state: .unknown, matchedText: "", confidence: 0,
                            rawTexts: [], activityScore: 0,
                            matchedActivityPatterns: [], textFingerprint: 0)
        }

        // 3. OCRDebug: persist the cropped image for tuning.
        if ocrDebugEnabled {
            saveDebugImage(cropped, bundleId: bundleId, region: rule.regionName)
        }

        // 4. Run Vision OCR → build the document (lines + merged paragraphs).
        let lines = recognizeText(in: cropped)
        let document = buildDocument(from: lines)
        // DIAG: log line count + a wider preview (12 lines) so we can see what OCR sees.
        let preview = lines.prefix(12).map { "「\($0.text)」(\(String(format:"%.2f",$0.confidence)))" }.joined(separator: " ")
        Logger.shared.logInfo("VisionDetector[\(bundleId)] OCR region=\(rule.regionName) lines=\(lines.count) paras=\(document.paragraphs.count) crop=\(cropped.width)x\(cropped.height): \(preview.isEmpty ? "(empty — 截图可能为黑屏/权限不足/裁图太小)" : preview)")

        // 5-7. Classify the OCR document. Keeping this pure-ish step separate
        // lets the real-scene fixture tests exercise the exact same precedence
        // and position filters without needing a live WindowServer capture.
        return classify(document: document,
                        cropHeight: CGFloat(cropped.height),
                        rule: rule,
                        bundleId: bundleId)
    }

    /// Classifies one OCR document using the production precedence:
    /// attention > completed > working > unknown. This is also the seam used
    /// by the real-scene fixture tests for WorkBuddy, Z Code, and ChatGPT.
    static func classify(document: OCRDocument,
                         cropHeight: CGFloat,
                         rule: OCRRule,
                         bundleId: String = "fixture") -> OCRResult {
        let rawTexts = document.lines.map { $0.text }
        let (activityScore, matchedPatterns) = scoreActivity(document: document, rule: rule)
        let fingerprint = computeFingerprint(rawTexts: rawTexts)

        let verdict = AttentionDetector.detect(document: document, rule: rule)
        if verdict.triggered {
            let result = OCRResult(state: .needsAttention,
                                   matchedText: verdict.matchedText,
                                   confidence: verdict.confidence,
                                   rawTexts: rawTexts,
                                   activityScore: activityScore,
                                   matchedActivityPatterns: matchedPatterns,
                                   textFingerprint: fingerprint)
            Logger.shared.logInfo("VisionDetector[\(bundleId)] VERDICT state=\(result.state) text=\"\(result.matchedText)\" conf=\(String(format:"%.2f",result.confidence)) score=\(String(format:"%.1f",verdict.score)) activityScore=\(activityScore)")
            return result
        }
        if let hit = bestMatch(in: document.lines,
                               keywords: rule.completedKeywords,
                               minConfidence: rule.completedMinConfidence,
                               cropHeight: cropHeight,
                               minY: rule.completedMinYFraction,
                               maxLineLength: rule.completedMaxLineLength) {
            let result = OCRResult(state: .completed,
                                   matchedText: hit.text,
                                   confidence: hit.confidence,
                                   rawTexts: rawTexts,
                                   activityScore: activityScore,
                                   matchedActivityPatterns: matchedPatterns,
                                   textFingerprint: fingerprint)
            Logger.shared.logInfo("VisionDetector[\(bundleId)] VERDICT state=\(result.state) text=\"\(result.matchedText)\" conf=\(String(format:"%.2f",result.confidence)) activityScore=\(activityScore)")
            return result
        }
        if let hit = bestMatch(in: document.lines,
                               keywords: rule.workingKeywords,
                               minConfidence: rule.workingMinConfidence,
                               cropHeight: cropHeight,
                               maxY: rule.workingMaxYFraction) {
            let result = OCRResult(state: .working,
                                   matchedText: hit.text,
                                   confidence: hit.confidence,
                                   rawTexts: rawTexts,
                                   activityScore: activityScore,
                                   matchedActivityPatterns: matchedPatterns,
                                   textFingerprint: fingerprint)
            Logger.shared.logInfo("VisionDetector[\(bundleId)] VERDICT state=\(result.state) text=\"\(result.matchedText)\" conf=\(String(format:"%.2f",result.confidence)) activityScore=\(activityScore)")
            return result
        }
        let result = OCRResult(state: .unknown, matchedText: "", confidence: 0,
                               rawTexts: rawTexts,
                               activityScore: activityScore,
                               matchedActivityPatterns: matchedPatterns,
                               textFingerprint: fingerprint)
        Logger.shared.logInfo("VisionDetector[\(bundleId)] VERDICT state=\(result.state) text=\"\(result.matchedText)\" conf=\(String(format:"%.2f",result.confidence)) activityScore=\(activityScore) patterns=\(matchedPatterns.count)")
        return result
    }

    // MARK: - Crop

    /// Crops `image` to the normalized `ratio` rect (origin top-left, fractions
    /// of the image). Returns nil if the region is empty.
    private static func crop(image: CGImage, to ratio: CGRect) -> CGImage? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        // CGImage coordinates are top-left origin; regionRatio is also top-left.
        let rect = CGRect(x: ratio.minX * w,
                          y: ratio.minY * h,
                          width: ratio.width * w,
                          height: ratio.height * h)
        guard rect.width > 1, rect.height > 1 else { return nil }
        return image.cropping(to: rect)
    }

    // MARK: - OCR

    /// Runs accurate multilingual text recognition. Returns recognized lines
    /// with their full bounding boxes (pixel coords in the cropped image,
    /// top-left origin), so callers can merge by proximity and filter by region.
    private static func recognizeText(in image: CGImage) -> [OCRLine] {
        var results: [OCRLine] = []
        let request = VNRecognizeTextRequest { req, _ in
            guard let observations = req.results as? [VNRecognizedTextObservation] else { return }
            for obs in observations {
                guard let candidate = obs.topCandidates(1).first else { continue }
                // Vision boundingBox is normalized, origin at BOTTOM-left (Y up).
                // Convert to pixel coords with top-left origin (Y down).
                let bb = obs.boundingBox
                let x: CGFloat = bb.origin.x * CGFloat(image.width)
                let y: CGFloat = (1.0 - bb.origin.y - bb.size.height) * CGFloat(image.height)
                let w: CGFloat = bb.size.width * CGFloat(image.width)
                let h: CGFloat = bb.size.height * CGFloat(image.height)
                let frame = CGRect(x: x, y: y, width: w, height: h)
                results.append(OCRLine(text: candidate.string,
                                       frame: frame,
                                       confidence: candidate.confidence))
            }
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US", "ja-JP"]
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Logger.shared.logWarning("VisionDetector: OCR perform failed: \(error.localizedDescription)")
        }
        return results
    }

    // MARK: - Document assembly (line → paragraph merging)

    /// Builds an `OCRDocument` from recognized lines by merging lines into
    /// paragraphs.
    ///
    /// Merge rule (per spec: y-distance + x-relationship + vertical continuity):
    /// - A line joins the current paragraph when its vertical center is within
    ///   `1.5 × lineHeight` of the paragraph's last line (vertical continuity),
    ///   AND its x-range overlaps or nearly touches the last line's x-range
    ///   (x-relationship — a left-aligned option list, or a centered title).
    /// - Lines are processed top-to-bottom, so paragraphs read in reading order.
    static func buildDocument(from lines: [OCRLine]) -> OCRDocument {
        // Sort top-to-bottom (Y down), then left-to-right for stable grouping.
        let sorted = lines.sorted {
            if abs($0.frame.midY - $1.frame.midY) > 4 {
                return $0.frame.midY < $1.frame.midY
            }
            return $0.frame.minX < $1.frame.minX
        }

        var paragraphs: [[OCRLine]] = []
        for line in sorted {
            guard var last = paragraphs.last?.last else {
                paragraphs.append([line])
                continue
            }
            // Vertical continuity: vertical gap must be small relative to line height.
            let gap = line.frame.midY - last.frame.midY
            let maxGap = max(last.frame.height, line.frame.height) * 1.5
            let verticallyContinuous = gap >= -maxGap && gap <= maxGap

            // x-relationship: x-ranges overlap, or nearly touch (≤ 40% of width).
            let overlap = min(line.frame.maxX, last.frame.maxX) - max(line.frame.minX, last.frame.minX)
            let xRelated = overlap >= -max(last.frame.width, line.frame.width) * 0.4

            if verticallyContinuous && xRelated {
                paragraphs[paragraphs.count - 1].append(line)
            } else {
                paragraphs.append([line])
            }
        }
        return OCRDocument(lines: sorted, paragraphs: paragraphs)
    }

    // MARK: - Keyword matching

    /// Returns the recognized line with the highest confidence that meets the
    /// threshold and contains any keyword (case-insensitive). Position filter:
    /// - `minY` non-nil: line's normalized Y must be ≥ minY (i.e. in the
    ///   bottom of the crop; for completed-keyword hits near the input box).
    /// - `maxY` non-nil: line's normalized Y must be ≤ maxY (i.e. in the
    ///   top of the crop; for working-keyword hits in the toolbar/status pill).
    /// Both may be passed simultaneously (intersection); pass nil for either to
    /// disable that bound.
    ///
    /// `cropHeight` is the height (in pixels) of the cropped image this match
    /// runs against. It MUST be passed explicitly per-detect: a shared static
    /// would be raced by concurrent detects for different apps and corrupt the
    /// Y normalization.
    private static func bestMatch(in lines: [OCRLine],
                                  keywords: [String],
                                  minConfidence: Float,
                                  cropHeight: CGFloat,
                                  minY: Float? = nil,
                                  maxY: Float? = nil,
                                  maxLineLength: Int? = nil) -> (text: String, confidence: Float)? {
        let lowerKeywords = keywords.map { $0.lowercased() }
        var best: (text: String, confidence: Float)? = nil
        for line in lines {
            guard line.confidence >= minConfidence else { continue }
            if let maxLineLength = maxLineLength,
               line.text.count > maxLineLength { continue }
            let normalizedY = Float(line.frame.midY / cropHeight)
            if let minY = minY, normalizedY < minY { continue }
            if let maxY = maxY, normalizedY > maxY { continue }
            let lower = line.text.lowercased()
            guard lowerKeywords.contains(where: { lower.contains($0) }) else { continue }
            if best == nil || line.confidence > best!.confidence {
                best = (line.text, line.confidence)
            }
        }
        return best
    }

    // MARK: - Activity patterns (compound AND-set match)

    /// Counts how many of `rule.workingActivityPatterns` fire in the current
    /// OCR frame. A pattern is a list of words that must ALL appear in the
    /// same frame (matched against `document.paragraphTexts` joined). Returns
    /// the count plus the list of patterns that hit — for `AppWatcher`'s
    /// sliding-window aggregation. Never directly sets `state`.
    private static func scoreActivity(document: OCRDocument,
                                     rule: OCRRule) -> (Int, [[String]]) {
        guard !rule.workingActivityPatterns.isEmpty else { return (0, []) }
        // Use paragraph text when available (preserves word order across
        // multi-line matches), fall back to joined raw lines.
        let haystack = document.paragraphTexts.isEmpty
            ? document.lines.map { $0.text }.joined(separator: " ")
            : document.paragraphTexts.joined(separator: " ")
        let lowerHay = haystack.lowercased()
        var hits: [[String]] = []
        for pattern in rule.workingActivityPatterns where !pattern.isEmpty {
            var allMatch = true
            for word in pattern {
                if !lowerHay.contains(word.lowercased()) { allMatch = false; break }
            }
            if allMatch { hits.append(pattern) }
        }
        return (hits.count, hits)
    }

    /// Stable fingerprint of the OCR frame's text. Used by `AppWatcher` to
    /// detect "text is still changing" (different hash → tool output flowing
    /// → keep working lease alive). A simple rolling hash over the joined
    /// raw texts is good enough — we only need a stable per-frame marker,
    /// not cryptographic strength.
    private static func computeFingerprint(rawTexts: [String]) -> UInt64 {
        let joined = rawTexts.joined(separator: " ▌ ")
        var hash: UInt64 = 1469598103934665603 // FNV-1a offset basis
        for byte in joined.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211              // FNV-1a prime
        }
        return hash
    }

    // MARK: - OCRDebug

    /// Reads the OCRDebug UserDefaults flag once per detection (cheap).
    private static var ocrDebugEnabled: Bool {
        UserDefaults.standard.bool(forKey: "OCRDebug")
    }

    /// Saves a cropped region image for offline tuning under
    /// ~/Library/Application Support/AgentMonitor/OCR/.
    private static func saveDebugImage(_ image: CGImage, bundleId: String, region: String) {
        let fm = FileManager.default
        guard let support = try? fm.url(for: .applicationSupportDirectory,
                                        in: .userDomainMask,
                                        appropriateFor: nil,
                                        create: true) else { return }
        let dir = support
            .appendingPathComponent("AgentMonitor", isDirectory: true)
            .appendingPathComponent("OCR", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let safeId = bundleId.replacingOccurrences(of: ".", with: "_")
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(safeId)_\(region)_\(stamp).png")
        try? png.write(to: url)
    }
}
