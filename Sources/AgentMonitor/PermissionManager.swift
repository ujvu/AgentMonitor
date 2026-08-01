import Foundation
import ApplicationServices
import CoreGraphics

/// Manages macOS permission checks for AgentMonitor: Accessibility and Screen
/// Recording. System notifications (UNUserNotificationCenter) are no longer used
/// — all status alerts are shown via the floating island UI.
///
/// All checks are thread-safe via a private serial dispatch queue.
/// Whenever a permission state changes, a corresponding `Notification.Name`
/// is posted on the main thread.
final class PermissionManager {

    // MARK: - Singleton

    static let shared = PermissionManager()

    // MARK: - Permission State

    enum PermissionState: Equatable {
        case granted
        case denied
        case notDetermined
        case unknown
    }

    // MARK: - Notification Names

    static let accessibilityChangedName =
        Notification.Name("agentMonitorAccessibilityChanged")
    static let screenRecordingChangedName =
        Notification.Name("agentMonitorScreenRecordingChanged")

    // MARK: - Properties

    /// Current accessibility permission state (thread-safe to read).
    var currentAccessibilityState: PermissionState {
        queue.sync { _accessibilityState }
    }

    /// Current screen recording permission state (thread-safe to read).
    var currentScreenRecordingState: PermissionState {
        queue.sync { _screenRecordingState }
    }

    private let queue = DispatchQueue(label: "cn.qwenwork.AgentMonitor.PermissionManager")

    private var _accessibilityState: PermissionState = .unknown
    private var _screenRecordingState: PermissionState = .unknown

    // MARK: - Init

    private init() {
        // Initial state; will be refreshed on first checkAllPermissions().
    }

    // MARK: - Accessibility

    /// Checks whether the process is trusted for Accessibility access.
    /// Uses `AXIsProcessTrusted()` (no prompt). Thread-safe.
    @discardableResult
    func checkAccessibility() -> Bool {
        let trusted = AXIsProcessTrusted()
        let newState: PermissionState = trusted ? .granted : .denied
        updateAccessibilityState(newState)
        return trusted
    }

    /// Requests Accessibility permission by showing the system prompt.
    /// Uses `AXIsProcessTrustedWithOptions` with the prompt key set to true.
    func requestAccessibility() {
        // kAXTrustedCheckOptionPrompt is the CFString constant key;
        // use the string literal directly since the constant may not be
        // imported into Swift scope.
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        let newState: PermissionState = trusted ? .granted : .notDetermined
        updateAccessibilityState(newState)
        Logger.shared.logInfo("Accessibility request triggered. Trusted=\(trusted)")
    }

    // MARK: - Screen Recording

    /// Checks whether the process has screen recording permission.
    ///
    /// `CGPreflightScreenCaptureAccess()` has a known issue on macOS 13+
    /// where it returns false even when permission is granted (especially
    /// after the app's code signature changes). As a more reliable fallback,
    /// we attempt an actual screen capture — if it produces a non-nil image,
    /// the permission is granted.
    @discardableResult
    func checkScreenRecording() -> Bool {
        if #available(macOS 10.15, *) {
            // Step 1: preflight check
            let preflight = CGPreflightScreenCaptureAccess()
            if preflight {
                updateScreenRecordingState(.granted)
                return true
            }

            // Step 2: preflight says no, but it may be wrong.
            // Try an actual capture — if we get an image, permission is granted.
            // CGWindowListCreateImage returns nil when permission is truly denied.
            let testRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            if let _ = CGWindowListCreateImage(
                testRect,
                [.optionOnScreenOnly],
                kCGNullWindowID,
                [.nominalResolution]
            ) {
                // Got an image — permission is actually granted
                updateScreenRecordingState(.granted)
                return true
            }

            // Both checks failed — permission is truly missing
            updateScreenRecordingState(.denied)
            return false
        } else {
            updateScreenRecordingState(.granted)
            return true
        }
    }

    /// Requests screen recording permission.
    /// Uses `CGRequestScreenCaptureAccess()` on macOS 10.15+.
    func requestScreenRecording() {
        if #available(macOS 10.15, *) {
            let granted = CGRequestScreenCaptureAccess()
            let newState: PermissionState = granted ? .granted : .notDetermined
            updateScreenRecordingState(newState)
            Logger.shared.logInfo("Screen recording request triggered. Granted=\(granted)")
        } else {
            updateScreenRecordingState(.granted)
        }
    }

    // MARK: - Re-check All

    /// Re-checks all permissions. Intended to be called on app activation
    /// (e.g. from `NSApplicationDidBecomeActive`). Thread-safe.
    func recheckAllPermissions() {
        checkAccessibility()
        checkScreenRecording()
    }

    // MARK: - Private State Updaters

    private func updateAccessibilityState(_ newState: PermissionState) {
        queue.async {
            let changed = (self._accessibilityState != newState)
            self._accessibilityState = newState
            if changed {
                Logger.shared.logInfo("Accessibility permission state -> \(newState)")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: PermissionManager.accessibilityChangedName,
                                                   object: nil)
                }
            }
        }
    }

    private func updateScreenRecordingState(_ newState: PermissionState) {
        queue.async {
            let changed = (self._screenRecordingState != newState)
            self._screenRecordingState = newState
            if changed {
                Logger.shared.logInfo("Screen recording permission state -> \(newState)")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: PermissionManager.screenRecordingChangedName,
                                                   object: nil)
                }
            }
        }
    }
}
