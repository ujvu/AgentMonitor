import Foundation

/// DeepSeek 官方账户余额接口：GET https://api.deepseek.com/user/balance
final class DeepSeekQuotaProvider: QuotaProvider {
    let id: QuotaProviderID = .deepseek
    let providerName = "DeepSeek"

    private let credentialStore: QuotaCredentialStore
    private let endpoint = URL(string: "https://api.deepseek.com/user/balance")!

    init(credentialStore: QuotaCredentialStore) {
        self.credentialStore = credentialStore
    }

    func fetchQuota(completion: @escaping (Result<QuotaSnapshot, QuotaProviderError>) -> Void) {
        let credential: String
        do {
            guard let stored = try credentialStore.credential(for: id), !stored.isEmpty else {
                completion(.success(.unconfigured(id)))
                return
            }
            credential = stored
        } catch let error as QuotaProviderError {
            completion(.failure(error))
            return
        } catch {
            completion(.failure(.transport(message: error.localizedDescription)))
            return
        }

        let request = QuotaHTTP.authorizedGET(url: endpoint, credential: credential)
        QuotaHTTP.session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(.transport(message: error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse, let data = data else {
                completion(.failure(.invalidResponse))
                return
            }
            guard (200...299).contains(http.statusCode) else {
                completion(.failure(http.statusCode == 401 || http.statusCode == 403
                    ? .authenticationFailed
                    : .server(statusCode: http.statusCode, message: nil)))
                return
            }

            do {
                let response = try JSONDecoder().decode(BalanceResponse.self, from: data)
                guard let selected = response.balanceInfos.first(where: {
                    $0.currency.uppercased() == "CNY"
                }) ?? response.balanceInfos.first else {
                    completion(.failure(.decoding(message: "响应缺少 balance_infos")))
                    return
                }

                guard let total = Self.decimal(selected.totalBalance) else {
                    completion(.failure(.decoding(message: "total_balance 不是有效金额")))
                    return
                }
                let balance = QuotaBalance(
                    currency: selected.currency,
                    total: total,
                    granted: Self.decimal(selected.grantedBalance),
                    toppedUp: Self.decimal(selected.toppedUpBalance),
                    isAvailable: response.isAvailable)
                let isEmpty = NSDecimalNumber(decimal: total).compare(NSDecimalNumber.zero) != .orderedDescending
                let state: QuotaState = response.isAvailable && !isEmpty ? .available : .exhausted
                completion(.success(QuotaSnapshot(
                    providerID: self.id,
                    providerName: self.providerName,
                    state: state,
                    windows: [],
                    balance: balance,
                    refreshedAt: Date(),
                    message: nil)))
            } catch {
                completion(.failure(.decoding(message: error.localizedDescription)))
            }
        }.resume()
    }

    private static func decimal(_ value: String?) -> Decimal? {
        guard let value = value else { return nil }
        return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
    }
}

private struct BalanceResponse: Decodable {
    let isAvailable: Bool
    let balanceInfos: [BalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

private struct BalanceInfo: Decodable {
    let currency: String
    let totalBalance: String
    let grantedBalance: String?
    let toppedUpBalance: String?

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }
}
