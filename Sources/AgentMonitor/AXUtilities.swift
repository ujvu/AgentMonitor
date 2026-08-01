import Foundation
import ApplicationServices
import AppKit

/// Safe wrappers around the macOS Accessibility (AX) API.
///
/// Every function catches errors, logs them via `Logger`, and returns
/// safe defaults (nil / empty array / etc.) so that callers never crash
/// due to an AX API failure. All CFTypeRef results are properly checked
/// for nil and safely cast.
enum AXUtilities {

    // MARK: - Permission

    /// Returns `true` if the process currently has Accessibility permission.
    /// Delegates to `PermissionManager` which uses `AXIsProcessTrusted()`.
    static func checkAccessibilityPermission() -> Bool {
        return PermissionManager.shared.checkAccessibility()
    }

    // MARK: - App Discovery

    /// Finds a running application's AXUIElement.
    ///
    /// First tries `NSRunningApplication` matching the bundle identifier,
    /// then falls back to matching by process name via `pgrep`.
    /// Returns `nil` if the app is not running (no crash).
    ///
    /// - Parameters:
    ///   - bundleId: The bundle identifier (e.g. "cn.qwenwork.desktop.mac").
    ///   - processName: The executable process name (e.g. "QwenWorkCN").
    /// - Returns: An AXUIElement for the application, or nil if not found.
    static func findApp(bundleId: String, processName: String) -> AXUIElement? {
        // 1. Try NSRunningApplication by bundle identifier.
        let runningApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleId
        )
        if let app = runningApps.first {
            guard app.processIdentifier > 0 else {
                Logger.shared.logDebug("findApp: app found by bundleId but PID invalid (\(bundleId))")
                return nil
            }
            return AXUIElementCreateApplication(app.processIdentifier)
        }

        // 2. Fall back to process name via pgrep.
        if let pid = findPIDByProcessName(processName) {
            Logger.shared.logDebug("findApp: found via pgrep (pid=\(pid), name=\(processName))")
            return AXUIElementCreateApplication(pid)
        }

        Logger.shared.logDebug("findApp: app not found (bundleId=\(bundleId), processName=\(processName))")
        return nil
    }

    /// Locates a PID by process name using `pgrep -x` (exact match).
    /// Returns the first matching PID, or `nil` if none found.
    private static func findPIDByProcessName(_ name: String) -> pid_t? {
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-x", name]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe() // suppress stderr

        do {
            try task.run()
        } catch {
            Logger.shared.logDebug("findPIDByProcessName: pgrep failed to launch: \(error.localizedDescription)")
            return nil
        }
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            return nil
        }

        // pgrep may return multiple PIDs (one per line); take the first.
        let firstLine = output.split(separator: "\n").first.map(String.init) ?? output
        guard let pid = pid_t(firstLine) else {
            Logger.shared.logDebug("findPIDByProcessName: could not parse PID from '\(firstLine)'")
            return nil
        }
        return pid
    }

    // MARK: - Windows

    /// Returns the focused window of the given application element.
    /// Falls back to the first window from `kAXWindowsAttribute` if
    /// `kAXFocusedWindowAttribute` is not supported (some Electron apps
    /// like WorkBuddy return -25212 for focusedWindow).
    static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        if error == .success, let result = value {
            guard CFGetTypeID(result) == AXUIElementGetTypeID() else {
                Logger.shared.logDebug("focusedWindow: returned value is not an AXUIElement")
                return nil
            }
            return (result as! AXUIElement)
        }

        // Fallback: try kAXWindowsAttribute and return the first window
        Logger.shared.logDebug("focusedWindow: kAXFocusedWindow failed (\(error.rawValue)), trying kAXWindows fallback")
        var windowsRef: CFTypeRef?
        let err2 = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        if err2 == .success, let windows = windowsRef as? [AXUIElement], let first = windows.first {
            return first
        }

        Logger.shared.logDebug("focusedWindow: kAXWindows fallback also failed")
        return nil
    }

    /// Returns all windows of the given application element.
    /// Returns an empty array on any error.
    static func allWindows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        if error != .success {
            Logger.shared.logDebug("allWindows: AXUIElementCopyAttributeValue failed (\(error.rawValue))")
            return []
        }
        guard let result = value else { return [] }
        guard let array = result as? [AXUIElement] else {
            Logger.shared.logDebug("allWindows: returned value is not an array of AXUIElement")
            return []
        }
        return array
    }

    // MARK: - Attribute Reading

    /// Reads a string attribute from an AX element.
    ///
    /// Handles CFString, Swift String, NSAttributedString, and arrays of
    /// strings (joined). Returns `nil` on any error.
    static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if error != .success {
            // Many elements simply lack the requested attribute; keep this quiet.
            return nil
        }
        guard let result = value else { return nil }

        // CFString / Swift String
        if let str = result as? String {
            return str
        }
        // Attributed string — extract plain string.
        if let attrStr = result as? NSAttributedString {
            return attrStr.string
        }
        // CFString via CoreFoundation type ID.
        if CFGetTypeID(result) == CFStringGetTypeID() {
            return result as? String
        }
        // Array of strings — join them.
        if let arr = result as? [String] {
            return arr.joined(separator: " ")
        }
        return nil
    }

    /// Convenience wrapper for `kAXRoleAttribute`.
    static func role(_ element: AXUIElement) -> String? {
        stringAttribute(element, kAXRoleAttribute as String)
    }

    /// Convenience wrapper for `kAXTitleAttribute`.
    static func title(_ element: AXUIElement) -> String? {
        stringAttribute(element, kAXTitleAttribute as String)
    }

    /// Convenience wrapper for `kAXValueAttribute`.
    static func value(_ element: AXUIElement) -> String? {
        stringAttribute(element, kAXValueAttribute as String)
    }

    /// Convenience wrapper for `kAXDescriptionAttribute`.
    static func desc(_ element: AXUIElement) -> String? {
        stringAttribute(element, kAXDescriptionAttribute as String)
    }

    /// Convenience wrapper for `kAXPlaceholderValueAttribute`.
    static func placeholder(_ element: AXUIElement) -> String? {
        stringAttribute(element, kAXPlaceholderValueAttribute as String)
    }

    // MARK: - State

    /// Returns whether an element is enabled.
    /// On any error, returns `true` (safe default: assume enabled).
    static func isEnabled(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value)
        if error != .success {
            // Many elements don't support this attribute; default to enabled.
            return true
        }
        guard let result = value else { return true }
        if let boolVal = result as? Bool {
            return boolVal
        }
        if let num = result as? NSNumber {
            return num.boolValue
        }
        // CFBoolean via CoreFoundation type ID.
        if CFGetTypeID(result) == CFBooleanGetTypeID() {
            return (result as? Bool) ?? true
        }
        return true
    }

    // MARK: - Children

    /// Returns the child elements of the given element.
    /// Returns an empty array on any error.
    static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        if error != .success {
            return []
        }
        guard let result = value else { return [] }
        guard let array = result as? [AXUIElement] else { return [] }
        return array
    }

    // MARK: - Tree Search

    /// Recursively searches the accessibility tree rooted at `element`.
    ///
    /// Traverses in depth-first order, collecting all matches. Never crashes;
    /// returns an empty array on any error.
    ///
    /// - Parameters:
    ///   - element: The root element to search from.
    ///   - maxDepth: Maximum recursion depth (default 15) to prevent runaway traversal.
    ///   - predicate: A closure that returns `true` when an element matches.
    /// - Returns: All matching elements.
    static func searchTree(
        _ element: AXUIElement,
        maxDepth: Int = 15,
        predicate: (AXUIElement) -> Bool
    ) -> [AXUIElement] {
        var results: [AXUIElement] = []
        searchTreeInternal(element, depth: 0, maxDepth: maxDepth,
                           predicate: predicate, results: &results)
        return results
    }

    /// Recursively searches the accessibility tree and returns the FIRST element
    /// matching `predicate` (depth-first order). Stops as soon as a match is
    /// found, so it is cheaper than `searchTree(...).first` when only one match
    /// is needed. Returns nil if nothing matches. Never crashes.
    static func searchFirst(
        _ element: AXUIElement,
        maxDepth: Int = 15,
        predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        return searchFirstInternal(element, depth: 0, maxDepth: maxDepth,
                                   predicate: predicate)
    }

    private static func searchFirstInternal(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        guard depth <= maxDepth else { return nil }

        // Evaluate the predicate. The predicate calls attribute-reading
        // helpers (role/title/value/etc.) that return nil on error — never throws.
        if predicate(element) {
            return element
        }

        // Recurse into children; return immediately when a descendant matches.
        let kids = children(of: element)
        for child in kids {
            if let hit = searchFirstInternal(child, depth: depth + 1,
                                             maxDepth: maxDepth,
                                             predicate: predicate) {
                return hit
            }
        }
        return nil
    }

    private static func searchTreeInternal(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        predicate: (AXUIElement) -> Bool,
        results: inout [AXUIElement]
    ) {
        guard depth <= maxDepth else { return }

        // Evaluate the predicate. The predicate calls attribute-reading
        // helpers (role/title/value/etc.) that return nil on error — never throws.
        if predicate(element) {
            results.append(element)
        }

        // Recurse into children.
        let kids = children(of: element)
        for child in kids {
            searchTreeInternal(child, depth: depth + 1, maxDepth: maxDepth,
                              predicate: predicate, results: &results)
        }
    }

    // MARK: - Keyword Search

    /// Finds elements whose title, value, description, or placeholder
    /// contains any of the given keywords (case-insensitive).
    ///
    /// - Parameters:
    ///   - element: Root element to search.
    ///   - keywords: Keywords to match (case-insensitive `contains`).
    ///   - maxDepth: Maximum recursion depth.
    /// - Returns: Matching elements (order preserved). Never crashes.
    static func findElementsContaining(
        _ element: AXUIElement,
        keywords: [String],
        maxDepth: Int = 15
    ) -> [AXUIElement] {
        let lowerKeywords = keywords.map { $0.lowercased() }

        return searchTree(element, maxDepth: maxDepth) { el in
            let texts = [title(el), value(el), desc(el), placeholder(el)].compactMap { $0 }
            for text in texts {
                let lower = text.lowercased()
                for keyword in lowerKeywords {
                    if lower.contains(keyword) {
                        return true
                    }
                }
            }
            return false
        }
    }

    /// Finds button-like elements matching any of the keywords by title
    /// or description.
    ///
    /// Filters by AX role (AXButton, AXPopUpButton, AXCheckBox, AXMenuBarItem,
    /// AXMenuItem, etc.) and matches title, description, or value.
    /// This avoids matching plain text in conversation history.
    ///
    /// - Parameters:
    ///   - keywords: Keywords to match (case-insensitive).
    ///   - window: The window element to search within (if nil, returns empty).
    ///   - maxDepth: Maximum recursion depth.
    /// - Returns: Matching button-like elements. Never crashes.
    static func findButtonsByTitleOrDescription(
        _ keywords: [String],
        window: AXUIElement?,
        maxDepth: Int = 15
    ) -> [AXUIElement] {
        guard let window = window else {
            Logger.shared.logDebug("findButtonsByTitleOrDescription: window is nil")
            return []
        }

        let lowerKeywords = keywords.map { $0.lowercased() }
        let buttonRoles: Set<String> = [
            "AXButton",
            "AXPopUpButton",
            "AXCheckBox",
            "AXMenuBarItem",
            "AXMenuItem",
            "AXMenuButton",
            "AXToolbarItem"
        ]

        return searchTree(window, maxDepth: maxDepth) { el in
            guard let r = role(el), buttonRoles.contains(r) else { return false }

            let texts = [title(el) ?? "", desc(el) ?? "", value(el) ?? ""]
            for text in texts {
                let lower = text.lowercased()
                for keyword in lowerKeywords {
                    if lower.contains(keyword) {
                        return true
                    }
                }
            }
            return false
        }
    }

    // MARK: - Match Helper

    /// Matches an element against a set of keywords with an explicit match mode.
    ///
    /// - Parameters:
    ///   - element: The element to check.
    ///   - keywords: Keywords to match (case-insensitive).
    ///   - matchMode: `.exact` (text must equal keyword) or `.contains` (text contains keyword).
    ///   - roles: AX roles to allow. Empty = any role.
    ///   - attributeKeys: Which attributes to read text from. Defaults to title, value, desc, placeholder.
    /// - Returns: `true` if the element matches.
    static func matchesElement(
        _ element: AXUIElement,
        keywords: [String],
        matchMode: MatchMode,
        roles: [String],
        attributeKeys: [String]? = nil
    ) -> Bool {
        if !roles.isEmpty {
            guard let r = role(element), roles.contains(r) else {
                return false
            }
        }

        let keys = attributeKeys ?? [
            kAXTitleAttribute as String,
            kAXValueAttribute as String,
            kAXDescriptionAttribute as String,
            kAXPlaceholderValueAttribute as String
        ]

        let lowerKeywords = keywords.map { $0.lowercased() }

        for key in keys {
            guard let text = stringAttribute(element, key) else { continue }
            let lower = text.lowercased()
            for keyword in lowerKeywords {
                switch matchMode {
                case .exact:
                    if lower == keyword { return true }
                case .contains:
                    if lower.contains(keyword) { return true }
                }
            }
        }
        return false
    }
}
