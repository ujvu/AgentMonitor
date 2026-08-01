import Foundation
import Security

/// 将各供应商 API Key 保存到 macOS Keychain。
/// service 固定，account 使用 QuotaProviderID；任何日志都不得输出密钥内容。
final class QuotaKeychainStore: QuotaCredentialStore {
    private let service = "com.cuishiming.AgentMonitor.quota"

    func credential(for providerID: QuotaProviderID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw QuotaProviderError.keychain(status: status)
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    func saveCredential(_ credential: String, for providerID: QuotaProviderID) throws {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuotaProviderError.missingCredential }
        let data = Data(trimmed.utf8)

        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw QuotaProviderError.keychain(status: updateStatus)
        }

        var addQuery = identity
        attributes.forEach { addQuery[$0.key] = $0.value }
        // Bind an ACL that trusts the running app (by code-signing identity) so
        // subsequent reads from AgentMonitor itself don't prompt for the login
        // password every launch. Without this, SecItemAdd creates a keychain
        // item with NO trusted app → every access prompts.
        if let access = makeSelfTrustedAccess() {
            addQuery[kSecAttrAccess as String] = access
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw QuotaProviderError.keychain(status: addStatus)
        }
    }

    /// Creates a `SecAccess` that trusts the running app so it can read its
    /// own keychain items without prompting for the login password on every
    /// launch.
    ///
    /// `SecTrustedApplicationCreateFromPath` reads the binary's code-signing
    /// designated requirement internally, so the trust is actually bound to
    /// the signing cert (stable across ditto redeploys), not just the path.
    /// We also add the system (nil path) as a principal for keychain infra.
    private func makeSelfTrustedAccess() -> SecAccess? {
        var trusted: [SecTrustedApplication] = []

        // (1) The app itself — trust is bound to its designated requirement.
        var selfApp: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(Bundle.main.bundleURL.path, &selfApp) == errSecSuccess,
           let app = selfApp {
            trusted.append(app)
        }

        // (2) System (nil path) — allows the OS keychain infrastructure.
        var systemApp: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &systemApp) == errSecSuccess,
           let sys = systemApp {
            trusted.append(sys)
        }

        guard !trusted.isEmpty else { return nil }
        var access: SecAccess?
        guard SecAccessCreate("AgentMonitor Quota" as CFString,
                              trusted as CFArray,
                              &access) == errSecSuccess else { return nil }
        return access
    }

    func deleteCredential(for providerID: QuotaProviderID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw QuotaProviderError.keychain(status: status)
        }
    }

    /// Recreates an existing item so its ACL is bound to the current signed
    /// AgentMonitor binary. SecItemUpdate does not reliably replace the legacy
    /// SecAccess ACL, which is why older installs can ask for Keychain access
    /// again after every restart.
    ///
    /// Returns false when no credential exists. The caller must only mark the
    /// migration complete after every existing item has been handled.
    func recreateCredentialWithCurrentAccess(for providerID: QuotaProviderID) throws -> Bool {
        guard let credential = try credential(for: providerID), !credential.isEmpty else {
            return false
        }
        try deleteCredential(for: providerID)
        try saveCredential(credential, for: providerID)
        return true
    }
}
