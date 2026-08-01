import Foundation
import ServiceManagement

/// Manages login-item (launch-at-login) support.
///
/// On macOS 13+ uses `SMAppService.mainApp`. On older macOS (12.x) falls back
/// to the deprecated `SMLoginItemSetEnabled` API, tracking state via
/// UserDefaults since the legacy API cannot reliably read the current state.
final class LoginItemManager {

    // MARK: - Singleton

    static let shared = LoginItemManager()
    private init() {}

    // MARK: - State

    /// Whether the login item is currently enabled.
    var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            return UserDefaults.standard.bool(forKey: Self.defaultsKey)
        }
    }

    // MARK: - Enable / Disable

    /// Enables launch-at-login. Throws on failure.
    func enable() throws {
        Logger.shared.logInfo("LoginItemManager: enable()")

        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                Logger.shared.logInfo("LoginItemManager: registered via SMAppService (status=\(SMAppService.mainApp.status.rawValue))")
            } catch {
                Logger.shared.logError("LoginItemManager: SMAppService.register failed — \(error.localizedDescription)")
                throw error
            }
        } else {
            let bundleId = Bundle.main.bundleIdentifier ?? ""
            guard !bundleId.isEmpty else {
                throw LoginItemError.noBundleIdentifier
            }
            let success = SMLoginItemSetEnabled(bundleId as CFString, true)
            guard success else {
                Logger.shared.logError("LoginItemManager: SMLoginItemSetEnabled(true) failed")
                throw LoginItemError.registrationFailed
            }
            UserDefaults.standard.set(true, forKey: Self.defaultsKey)
            Logger.shared.logInfo("LoginItemManager: enabled via SMLoginItemSetEnabled")
        }
    }

    /// Disables launch-at-login. Throws on failure.
    func disable() throws {
        Logger.shared.logInfo("LoginItemManager: disable()")

        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.unregister()
                Logger.shared.logInfo("LoginItemManager: unregistered via SMAppService")
            } catch {
                Logger.shared.logError("LoginItemManager: SMAppService.unregister failed — \(error.localizedDescription)")
                throw error
            }
        } else {
            let bundleId = Bundle.main.bundleIdentifier ?? ""
            guard !bundleId.isEmpty else {
                throw LoginItemError.noBundleIdentifier
            }
            let success = SMLoginItemSetEnabled(bundleId as CFString, false)
            guard success else {
                Logger.shared.logError("LoginItemManager: SMLoginItemSetEnabled(false) failed")
                throw LoginItemError.registrationFailed
            }
            UserDefaults.standard.set(false, forKey: Self.defaultsKey)
            Logger.shared.logInfo("LoginItemManager: disabled via SMLoginItemSetEnabled")
        }
    }

    // MARK: - Toggle

    /// Toggles the login item. Returns the new state.
    @discardableResult
    func toggle() throws -> Bool {
        if isEnabled {
            try disable()
            return false
        } else {
            try enable()
            return true
        }
    }

    // MARK: - Constants

    private static let defaultsKey = "loginItemEnabled"

    // MARK: - Errors

    enum LoginItemError: LocalizedError {
        case noBundleIdentifier
        case registrationFailed

        var errorDescription: String? {
            switch self {
            case .noBundleIdentifier:
                return "无法获取应用 Bundle Identifier，无法设置开机启动项。"
            case .registrationFailed:
                return "设置开机启动项失败，请检查应用权限。"
            }
        }
    }
}
