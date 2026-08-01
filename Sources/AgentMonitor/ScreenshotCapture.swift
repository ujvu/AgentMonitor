import Cocoa
import CoreGraphics

/// Captures screenshots of app windows for the notification preview.
///
/// Uses `CGWindowListCreateImage` (NOT ScreenCaptureKit) and checks screen-
/// recording permission via `PermissionManager` before any capture.
enum ScreenshotCapture {

    // MARK: - CaptureError

    /// Typed capture failures so callers (notification preview, Vision OCR) can
    /// react differently to permission loss vs. a missing window vs. a genuine
    /// capture glitch — instead of guessing from a nil.
    enum CaptureError: Error, Equatable {
        case noPermission       // Screen Recording permission not granted
        case appNotRunning      // No running process for this bundle id
        case noWindow           // Running, but no on-screen window
        case windowZeroSize     // Window exists but has 0×0 bounds
        case captureFailed      // CGWindowListCreateImage returned nil
    }

    // MARK: - Core capture (Result-returning, shared)

    /// Captures the on-screen window of `bundleId` as a raw `CGImage`.
    ///
    /// This is the shared primitive used by both the notification-thumbnail
    /// path and the Vision OCR path. It returns a typed `Result` so callers can
    /// distinguish permission loss from a transient missing window.
    static func captureWindowImage(bundleId: String) -> Result<CGImage, CaptureError> {
        // Permission check before any capture.
        guard PermissionManager.shared.checkScreenRecording() else {
            return .failure(.noPermission)
        }

        guard let windowId = findWindowId(bundleId: bundleId) else {
            // findWindowId already distinguishes not-running vs. no-window via
            // its logs, but we surface noWindow here (running apps with no
            // on-screen window is the common case for hidden/background apps).
            let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleId).first?.processIdentifier ?? 0
            return .failure(running > 0 ? .noWindow : .appNotRunning)
        }

        // Verify the window has a non-zero size.
        if let bounds = windowBounds(windowId) {
            if bounds.width == 0 || bounds.height == 0 {
                return .failure(.windowZeroSize)
            }
        }

        // Capture the single window. CGRect.null captures the window's full
        // bounds regardless of where it is on screen.
        guard let cgImage = CGWindowListCreateImage(
            CGRect.null,
            .optionIncludingWindow,
            windowId,
            [.bestResolution]
        ) else {
            return .failure(.captureFailed)
        }

        // ChatGPT's Electron surface currently returns a fully black image
        // through CGWindowListCreateImage even though the same window is
        // visible in a normal screen capture. Use a display capture and crop
        // the exact window bounds for this protected renderer surface.
        if bundleId == "com.openai.codex",
           let visibleCrop = captureVisibleScreenRegion(windowId: windowId) {
            Logger.shared.logInfo(
                "ScreenshotCapture: ChatGPT renderer uses visible-screen crop (\(visibleCrop.width))×\(visibleCrop.height)")
            return .success(visibleCrop)
        }

        return .success(cgImage)
    }

    // MARK: - NSImage convenience (notification preview path)

    /// Captures the on-screen window belonging to the app with the given
    /// bundle identifier. Returns `nil` (never crashes) on any error.
    static func captureWindow(bundleId: String) -> NSImage? {
        switch captureWindowImage(bundleId: bundleId) {
        case .success(let cgImage):
            let pixelW = CGFloat(cgImage.width)
            let pixelH = CGFloat(cgImage.height)
            let image = NSImage(cgImage: cgImage,
                                size: NSSize(width: pixelW, height: pixelH))
            Logger.shared.logDebug("ScreenshotCapture: captured \(pixelW)×\(pixelH) for \(bundleId)")
            return image
        case .failure(let err):
            Logger.shared.logError("ScreenshotCapture: \(err) (\(bundleId))")
            return nil
        }
    }

    /// Returns a downscaled thumbnail suitable for the notification preview.
    static func captureThumbnail(bundleId: String, maxWidth: CGFloat = 400) -> NSImage? {
        guard let full = captureWindow(bundleId: bundleId) else { return nil }
        let origSize = full.size
        guard origSize.width > 0, origSize.height > 0 else { return nil }
        if origSize.width <= maxWidth {
            return full
        }
        let scale = maxWidth / origSize.width
        let newSize = NSSize(width: maxWidth, height: origSize.height * scale)
        let thumbnail = NSImage(size: newSize)
        thumbnail.lockFocus()
        full.draw(in: NSRect(origin: .zero, size: newSize),
                  from: .zero,
                  operation: .copy,
                  fraction: 1.0)
        thumbnail.unlockFocus()
        return thumbnail
    }

    // MARK: - Window Lookup

    /// Finds the CG window ID (CGWindowID / UInt32) for the topmost on-screen
    /// window belonging to the app identified by `bundleId`.
    static func findWindowId(bundleId: String) -> UInt32? {
        let runningApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleId
        )
        // An app (esp. Electron) can have multiple processes — a main process
        // that owns the on-screen window plus helper/renderer processes that
        // have no window. `runningApplications.first` is NOT guaranteed to be
        // the window-owning process (it often resolves to a helper PID with no
        // window), so collect *all* PIDs for this bundle id and match any
        // window whose ownerPID is in that set.
        let pids = Set(runningApps.compactMap { $0.processIdentifier > 0 ? Int32($0.processIdentifier) : nil })
        guard !pids.isEmpty else {
            Logger.shared.logDebug("ScreenshotCapture.findWindowId: app not running (\(bundleId))")
            return nil
        }

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            Logger.shared.logError("ScreenshotCapture.findWindowId: CGWindowListCopyWindowInfo failed")
            return nil
        }

        // Electron/Codex apps can expose several on-screen windows for one
        // process: small mascot/pet surfaces, voice controls, popovers, and
        // the real conversation window. Returning the first matching window
        // is not deterministic (and for ChatGPT often selects an ~874×240
        // pet surface), which makes OCR read an empty/irrelevant image. Pick
        // the largest usable window instead; the main conversation surface is
        // consistently the largest window owned by the app.
        var candidates: [(id: UInt32, width: CGFloat, height: CGFloat, name: String)] = []
        for info in windowList {
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pids.contains(ownerPID),
                  let wid = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let width = (boundsDict["Width"] as? NSNumber)?.doubleValue,
                  let height = (boundsDict["Height"] as? NSNumber)?.doubleValue,
                  width > 0, height > 0 else { continue }

            let name = info[kCGWindowName as String] as? String ?? ""
            candidates.append((id: wid, width: CGFloat(width), height: CGFloat(height), name: name))
        }

        if let selected = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            Logger.shared.logDebug(
                "ScreenshotCapture.findWindowId: selected window \(selected.id) \(Int(selected.width))×\(Int(selected.height)) name=\"\(selected.name)\" from \(candidates.count) candidates (\(bundleId))")
            return selected.id
        }

        Logger.shared.logWarning("ScreenshotCapture.findWindowId: no on-screen window for PIDs \(pids)")
        return nil
    }

    /// Reads the bounds rectangle for a given CG window ID.
    private static func windowBounds(_ windowId: UInt32) -> CGRect? {
        guard let array = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            windowId
        ) as? [[String: Any]],
              let info = array.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any] else {
            return nil
        }
        guard let x = (boundsDict["X"] as? NSNumber)?.doubleValue,
              let y = (boundsDict["Y"] as? NSNumber)?.doubleValue,
              let w = (boundsDict["Width"] as? NSNumber)?.doubleValue,
              let h = (boundsDict["Height"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Captures the active display and crops the on-screen bounds of a window.
    /// CGWindow bounds and display images use the same top-left screen-space
    /// orientation on macOS; scale conversion handles Retina displays.
    private static func captureVisibleScreenRegion(windowId: UInt32) -> CGImage? {
        guard let bounds = windowBounds(windowId),
              bounds.width > 0, bounds.height > 0 else { return nil }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let displayID = CGMainDisplayID()
        let displayBounds = CGDisplayBounds(displayID)
        guard displayBounds.contains(center),
              let displayImage = CGDisplayCreateImage(displayID) else { return nil }

        let scaleX = CGFloat(displayImage.width) / displayBounds.width
        let scaleY = CGFloat(displayImage.height) / displayBounds.height
        let cropRect = CGRect(
            x: (bounds.minX - displayBounds.minX) * scaleX,
            y: (bounds.minY - displayBounds.minY) * scaleY,
            width: bounds.width * scaleX,
            height: bounds.height * scaleY)
            .intersection(CGRect(x: 0, y: 0,
                                 width: CGFloat(displayImage.width),
                                 height: CGFloat(displayImage.height)))

        guard !cropRect.isNull, cropRect.width > 1, cropRect.height > 1 else { return nil }
        return displayImage.cropping(to: cropRect)
    }

}
