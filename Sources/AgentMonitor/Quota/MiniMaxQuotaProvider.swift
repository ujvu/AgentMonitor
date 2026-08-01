import Foundation

/// MiniMax Token Plan 官方余量接口。
/// 官方已公开请求地址与认证方式；响应解析采用容错字典读取，以兼容字段扩展。
final class MiniMaxQuotaProvider: QuotaProvider {
    let id: QuotaProviderID = .minimax
    let providerName = "MiniMax"

    private let credentialStore: QuotaCredentialStore
    private let endpoint = URL(string: "https://www.minimaxi.com/v1/token_plan/remains")!

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
                let object = try JSONSerialization.jsonObject(with: data)
                guard let root = object as? [String: Any] else {
                    completion(.failure(.decoding(message: "顶层 JSON 不是对象")))
                    return
                }

                if let base = root["base_resp"] as? [String: Any],
                   let code = Self.double(base["status_code"]),
                   code != 0 {
                    let message = base["status_msg"] as? String
                    completion(.failure(code == 1004
                        ? .authenticationFailed
                        : .server(statusCode: Int(code), message: message)))
                    return
                }

                guard let remains = root["model_remains"] as? [[String: Any]],
                      let selected = remains.first(where: {
                          (($0["model_name"] as? String)?.lowercased() == "general")
                      }) ?? remains.first else {
                    completion(.failure(.decoding(message: "响应缺少 model_remains")))
                    return
                }

                let intervalPercent = Self.double(selected["current_interval_remaining_percent"])
                let weeklyPercent = Self.double(selected["current_weekly_remaining_percent"])
                let intervalUsage = Self.double(selected["current_interval_usage_count"])
                let weeklyUsage = Self.double(selected["current_weekly_usage_count"])

                // 实测字段（2026-07-31）：5小时窗口的结束时间 = `end_time`，
                // 周窗口结束 = `weekly_end_time`；`remains_time` 为剩余秒数。
                // （旧代码误用 `*_reset_time`，接口无此字段 → 恢复时间恒为 nil）
                let intervalReset = Self.date(in: selected,
                    keys: ["end_time", "current_interval_end_time", "interval_reset_time"])
                    ?? Self.dateFromRemaining(selected["remains_time"])
                let weeklyReset = Self.date(in: selected,
                    keys: ["weekly_end_time", "current_weekly_end_time", "weekly_reset_time"])
                    ?? Self.dateFromRemaining(selected["weekly_remains_time"])

                let values = [intervalPercent, weeklyPercent].compactMap { $0 }
                let minimum = values.min()
                let state: QuotaState
                if let minimum = minimum, minimum <= 0 {
                    state = .exhausted
                } else if let minimum = minimum, minimum <= 20 {
                    state = .warning
                } else {
                    state = .available
                }

                let snapshot = QuotaSnapshot(
                    providerID: self.id,
                    providerName: self.providerName,
                    state: state,
                    windows: [
                        QuotaWindow(name: "5小时", remainingPercent: intervalPercent,
                                    usageCount: intervalUsage, resetAt: intervalReset),
                        QuotaWindow(name: "周额度", remainingPercent: weeklyPercent,
                                    usageCount: weeklyUsage, resetAt: weeklyReset)
                    ],
                    balance: nil,
                    refreshedAt: Date(),
                    message: nil)
                completion(.success(snapshot))
            } catch {
                completion(.failure(.decoding(message: error.localizedDescription)))
            }
        }.resume()
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func date(in object: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let number = double(value) {
                let seconds = number > 10_000_000_000 ? number / 1000 : number
                return Date(timeIntervalSince1970: seconds)
            }
            if let text = value as? String {
                if let numeric = Double(text) {
                    let seconds = numeric > 10_000_000_000 ? numeric / 1000 : numeric
                    return Date(timeIntervalSince1970: seconds)
                }
                if let iso = ISO8601DateFormatter().date(from: text) { return iso }
            }
        }
        return nil
    }

    /// `remains_time`（剩余秒数）→ 恢复时间 = now + seconds。end_time 缺失时兜底。
    private static func dateFromRemaining(_ value: Any?) -> Date? {
        guard let seconds = double(value), seconds > 0 else { return nil }
        return Date().addingTimeInterval(seconds)
    }
}
