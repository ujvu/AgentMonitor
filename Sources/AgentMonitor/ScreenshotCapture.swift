import Cocoa
import ScreenCaptureKit
import CoreGraphics

/// Captures screenshots of app windows for the notification preview.
///
/// Uses CGWindowListCreateImage for the window-level screenshot — this is
/// the simplest approach and works without additional permissions for
/// most apps.
enum ScreenshotCapture {

    /// Captures a screenshot of the specified app's window.
    /// Returns an NSImage of the window contents, or nil if the window
    /// can't be found or captured.
    static func captureWindow(bundleId: String) -> NSImage? {
        guard let windowId = findWindowId(bundleId: bundleId) else {
            return nil
        }

        // Capture just this window (not the whole screen)
        let rect = CGRect.null  // null = capture the full window
        let image = CGWindowListCreateImage(
            rect,
            [.optionIncludingWindow],
            CGWindowID(windowId),
            [.boundsIgnoreFraming, .nominalResolution]
        )

        guard let cgImage = image else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let nsImage = NSImage(size: bitmap.size)
        nsImage.addRepresentation(bitmap)
        return nsImage
    }

    /// Captures a downscaled thumbnail suitable for the notification preview.
    static func captureThumbnail(bundleId: String, maxWidth: CGFloat = 400) -> NSImage? {
        guard let fullImage = captureWindow(bundleId: bundleId) else { return nil }
        let aspect = fullImage.size.height / fullImage.size.width
        let newSize = NSSize(width: maxWidth, height: maxWidth * aspect)
        let thumbnail = NSImage(size: newSize)
        thumbnail.lockFocus()
        fullImage.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        thumbnail.unlockFocus()
        return thumbnail
    }

    // MARK: - Window Discovery

    /// Finds the CG window ID for an app by bundle identifier.
    private static func findWindowId(bundleId: String) -> UInt32? {
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        // Find by PID — more reliable than matching by process name
        guard let runningApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleId
        ).first else { return nil }

        let pid = runningApp.processIdentifier

        for info in windowInfo {
            guard let ownerPid = info[kCGWindowOwnerPID as String] as? Int32 else { continue }
            guard ownerPid == pid else { continue }

            // Skip windows with no bounds (menu bar items, etc.)
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let width = bounds["Width"] ?? 0
            let height = bounds["Height"] ?? 0
            if width < 100 || height < 100 { continue }

            // Skip overlay/utility windows — prefer the main window
            // (layer 0 = normal window)
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 { continue }

            return info[kCGWindowNumber as String] as? UInt32
        }

        // If no normal window found, take any window with reasonable size
        for info in windowInfo {
            guard let ownerPid = info[kCGWindowOwnerPID as String] as? Int32, ownerPid == pid else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let width = bounds["Width"] ?? 0
            let height = bounds["Height"] ?? 0
            if width >= 100 && height >= 100 {
                return info[kCGWindowNumber as String] as? UInt32
            }
        }

        return nil
    }
}
