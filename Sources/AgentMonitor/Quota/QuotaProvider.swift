import Foundation

/// 安全凭据存储。实现必须使用系统 Keychain，禁止写入 UserDefaults 或文件。
protocol QuotaCredentialStore {
    func credential(for providerID: QuotaProviderID) throws -> String?
    func saveCredential(_ credential: String, for providerID: QuotaProviderID) throws
    func deleteCredential(for providerID: QuotaProviderID) throws
}

/// 所有额度供应商的统一接口。
protocol QuotaProvider {
    var id: QuotaProviderID { get }
    var providerName: String { get }

    func fetchQuota(completion: @escaping (Result<QuotaSnapshot, QuotaProviderError>) -> Void)
}

enum QuotaProviderError: LocalizedError {
    case missingCredential
    case invalidURL
    case invalidResponse
    case authenticationFailed
    case server(statusCode: Int, message: String?)
    case decoding(message: String)
    case transport(message: String)
    case keychain(status: Int32)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "未配置 API Key"
        case .invalidURL:
            return "额度接口地址无效"
        case .invalidResponse:
            return "额度接口返回无效响应"
        case .authenticationFailed:
            return "API Key 无效或无权查询额度"
        case let .server(statusCode, message):
            return message.map { "接口错误（\(statusCode)）：\($0)" } ?? "接口错误（\(statusCode)）"
        case let .decoding(message):
            return "额度响应解析失败：\(message)"
        case let .transport(message):
            return "网络请求失败：\(message)"
        case let .keychain(status):
            return "Keychain 操作失败（\(status)）"
        }
    }
}

/// 额度 HTTP 请求统一使用短超时、无缓存会话。
enum QuotaHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    static func authorizedGET(url: URL, credential: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        return request
    }
}
