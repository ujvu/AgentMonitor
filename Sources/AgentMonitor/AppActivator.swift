import Cocoa

/// Brings a target app to the foreground so the user can interact with it.
///
/// Uses `NSRunningApplication.activate()` on macOS 14+, falls back to
/// `.activateAllWindows`, and tries AppleScript as a last resort.
enum AppActivator {

    /// Activates the app with the given bundle identifier.
    static func activate(bundleId: String) {
        Logger.shared.logInfo("AppActivator: activating bundleId=\(bundleId)")

        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleId
        )

        guard let target = running.first else {
            // App not running — try to launch it.
            Logger.shared.logWarning("AppActivator: app not running, attempting launch")
            if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleId
            ) {
                NSWorkspace.shared.openApplication(at: url,
                                                   configuration: NSWorkspace.OpenConfiguration())
                Logger.shared.logInfo("AppActivator: launched \(bundleId)")
            } else {
                Logger.shared.logError("AppActivator: could not find app for \(bundleId)")
            }
            return
        }

        // Activate the running app.
        if #available(macOS 14.0, *) {
            target.activate()
            Logger.shared.logDebug("AppActivator: activate() (macOS 14+)")
        } else {
            target.activate(options: [.activateAllWindows])
            Logger.shared.logDebug("AppActivator: activateAllWindows (fallback)")
        }

        // AppleScript backup to ensure the window comes to front.
        activateViaAppleScript(bundleId: bundleId)
    }

    /// Best-effort AppleScript activation backup.
    private static func activateViaAppleScript(bundleId: String) {
        // Resolve a display name / bundle for AppleScript's "activate".
        let script: String
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleId
        ) {
            // Use the app's file URL path in a Finder-style activate.
            let path = url.path.replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            tell application "\(path)" to activate
            """
        } else {
            // Fallback: activate by bundle id via System Events (best effort).
            script = """
            tell application "System Events"
                set p to first application process whose bundle identifier is "\(bundleId)"
                set frontmost of p to true
            end tell
            """
        }

        DispatchQueue.global(qos: .utility).async {
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                let _ = appleScript.executeAndReturnError(&error)
                if let error = error {
                    Logger.shared.logDebug("AppActivator: AppleScript backup result: \(error)")
                }
            }
        }
    }
}
