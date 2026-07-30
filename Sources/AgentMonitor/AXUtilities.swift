import ApplicationServices
import Cocoa

/// Helper utilities for the macOS Accessibility (AX) API.
///
/// The AX API is the standard way to inspect and interact with UI elements
/// of other applications. We use it to read window trees, find buttons, and
/// detect state changes.
enum AXUtilities {

    // MARK: - Permission

    /// Checks whether we have Accessibility permission; if not, prompts the
    /// user to grant it via the system dialog.
    @discardableResult
    static func checkAccessibilityPermission() -> Bool {
        let opts: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Finding Apps

    /// Returns the AXUIElement for a running application by bundle identifier,
    /// falling back to process name matching.
    static func findApp(bundleId: String, processName: String) -> AXUIElement? {
        // Try by bundle ID via NSRunningApplication
        if let runningApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleId
        ).first {
            return AXUIElementCreateApplication(runningApp.processIdentifier)
        }

        // Fallback: search by process name using NSWorkspace
        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            if app.localizedName == processName || app.bundleIdentifier == bundleId {
                return AXUIElementCreateApplication(app.processIdentifier)
            }
        }

        // Last resort: use process name via launchctl-style lookup
        if let pid = findPID(forProcess: processName) {
            return AXUIElementCreateApplication(pid)
        }

        return nil
    }

    /// Find a PID by process name using `pgrep`.
    private static func findPID(forProcess name: String) -> pid_t? {
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-x", name]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = pid_t(str) {
                return pid
            }
        } catch {}
        return nil
    }

    // MARK: - Window Access

    /// Gets the focused (key) window of an application.
    static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        var windowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard result == .success, let window = windowRef else { return nil }
        return (window as! AXUIElement)
    }

    /// Gets all windows of an application.
    static func allWindows(of app: AXUIElement) -> [AXUIElement] {
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement] else { return [] }
        return windows
    }

    // MARK: - Attribute Reading

    /// Reads a string attribute value from an AX element.
    static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard result == .success, let value = ref else { return nil }
        if let str = value as? String { return str }
        if let arr = value as? [String] { return arr.joined(separator: " ") }
        return nil
    }

    /// Reads the element's role (e.g. "AXButton", "AXTextField").
    static func role(_ element: AXUIElement) -> String? {
        stringAttribute(element, kAXRoleAttribute)
    }

    /// Reads the element's title.
    static func title(_ element: AXUIElement) -> String? {
        stringAttribute(element, kAXTitleAttribute)
    }

    /// Reads the element's value (text content for text fields, state for buttons).
    static func value(_ element: AXUIElement) -> String? {
        stringAttribute(element, kAXValueAttribute)
    }

    /// Reads the element's description (often used for accessibility labels).
    static func desc(_ element: AXUIElement) -> String? {
        stringAttribute(element, kAXDescriptionAttribute)
    }

    /// Reads the element's placeholder value (for text fields).
    static func placeholder(_ element: AXUIElement) -> String? {
        stringAttribute(element, kAXPlaceholderValueAttribute)
    }

    /// Checks if a button is enabled.
    static func isEnabled(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &ref)
        guard result == .success, let val = ref as? Bool else { return true }
        return val
    }

    /// Gets all child elements.
    static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref)
        guard result == .success, let kids = ref as? [AXUIElement] else { return [] }
        return kids
    }

    // MARK: - Tree Search

    /// Recursively searches the AX tree for elements matching a predicate.
    /// Traverses in depth-first order, collecting all matches.
    /// - Parameters:
    ///   - element: Root element to search from.
    ///   - maxDepth: Maximum tree depth to traverse (prevents runaway searches).
    ///   - predicate: Returns true for elements that match.
    static func searchTree(
        _ element: AXUIElement,
        maxDepth: Int = 15,
        predicate: (AXUIElement, [String: String]) -> Bool
    ) -> [AXUIElement] {
        var results: [AXUIElement] = []
        searchTreeHelper(element, depth: 0, maxDepth: maxDepth, predicate: predicate, results: &results)
        return results
    }

    private static func searchTreeHelper(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        predicate: (AXUIElement, [String: String]) -> Bool,
        results: inout [AXUIElement]
    ) {
        guard depth <= maxDepth else { return }

        // Gather attributes lazily — only if the predicate needs them.
        let attrs: [String: String] = [
            "role": role(element) ?? "",
            "title": title(element) ?? "",
            "value": value(element) ?? "",
            "desc": desc(element) ?? "",
            "placeholder": placeholder(element) ?? "",
        ]

        if predicate(element, attrs) {
            results.append(element)
        }

        for child in children(of: element) {
            searchTreeHelper(child, depth: depth + 1, maxDepth: maxDepth, predicate: predicate, results: &results)
        }
    }

    /// Convenience: search for any element whose combined text (title + value + description + placeholder)
    /// contains one of the given keywords.
    static func findElementsContaining(_ element: AXUIElement, keywords: [String], maxDepth: Int = 15) -> [AXUIElement] {
        searchTree(element, maxDepth: maxDepth) { _, attrs in
            let combined = (attrs["title"]! + " " + attrs["value"]! + " " + attrs["desc"]! + " " + attrs["placeholder"]!).lowercased()
            return keywords.contains { combined.contains($0.lowercased()) }
        }
    }
}
