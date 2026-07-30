import Cocoa

/// Brings a target app to the foreground so the user can interact with it.
enum AppActivator {

    /// Activates the app with the given bundle identifier.
    /// Brings all its windows to front.
    static func activate(bundleId: String) {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleId
        ).first else {
            // App not running — nothing to activate
            return
        }

        // Use the newer API if available (macOS 14+), otherwise fallback
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateAllWindows])
        }

        // Also use AppleScript as a belt-and-suspenders approach
        let procName = app.localizedName ?? bundleId
        DispatchQueue.main.async {
            let script = """
            tell application "\(procName)" to activate
            """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if let error = error {
                    print("⚠️ AppleScript activate error: \(error)")
                }
            }
        }
    }
}
