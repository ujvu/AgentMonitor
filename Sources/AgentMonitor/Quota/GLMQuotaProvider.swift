import Foundation

/// 智谱 GLM Coding Plan 配额接口。
///
/// 官方未提供现金余额查询接口，但 Coding Plan 订阅提供额度窗口查询：
///   GET https://open.bigmodel.cn/api/monitor/usage/quota/limit
///   Authorization: Bearer <API Key>
///
/// 响应结构（实测，2026-07-31）：
/// ```json
/// {
///   "code": 200, "msg": "操作成功", "success": true,
///   "data": {
///     "level": "lite",
///     "limits": [
///       {"type": "TIME_LIMIT",  "unit": 5, "usage": 100, "currentValue": 22,
///        "remaining": 78, "percentage": 22, "nextResetTime": 1786154424993},
///       {"type": "TOKENS_LIMIT","unit": 3, "number": 5, "percentage": 100,
///        "nextResetTime": 1785511581328},
///       {"type": "TOKENS_LIMIT","unit": 6, "number": 1, "percentage": 40,
///        "nextResetTime": 1786068024998}
///     ]
///   }
/// }
/// ```
///
/// ### 字段语义（实测 + 第三方实现核对，2026-08-18 修正）
/// - **`percentage` 是「已使用百分比」，不是剩余百分比！** 例：percentage=22
///   表示已用 22%，剩余 78%。TIME_LIMIT 条目同时带 `remaining`（真实剩余值，
///   优先使用）；TOKENS_LIMIT 条目只有 `percentage`，剩余必须用 100-percentage。
/// - **unit 语义（易踩坑，曾误标）**：
///   - `TOKENS_LIMIT unit=3 number=5` → **5小时 Token 限额**（5h 滚动窗口，重置最快）
///   - `TOKENS_LIMIT unit=6 number=1` → **每周 Token 限额**
///   - `TIME_LIMIT  unit=5`            → **MCP 月度配额**（搜索次数，每月重置）
///   与智谱官方后台「用量统计」三张卡片一一对应：每5小时 / 每周 / MCP每月。
/// - `nextResetTime` 为毫秒时间戳，是额度恢复时间。
final class GLMQuotaProvider: QuotaProvider {
    let id: QuotaProviderID = .glm
    let providerName = "智谱 GLM"

    private let credentialStore: QuotaCredentialStore
    private let endpoint = URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!

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

                // 业务码：code != 200（或 !success）视为失败。
                if let code = Self.int(root["code"]), code != 200 {
                    let message = root["msg"] as? String
                    completion(.failure(code == 401 || code == 403
                        ? .authenticationFailed
                        : .server(statusCode: code, message: message)))
                    return
                }
                if let success = root["success"] as? Bool, success == false {
                    completion(.failure(.server(statusCode: 0, message: root["msg"] as? String)))
                    return
                }

                guard let dataObject = root["data"] as? [String: Any] else {
                    completion(.failure(.decoding(message: "响应缺少 data")))
                    return
                }
                guard let limits = dataObject["limits"] as? [[String: Any]] else {
                    completion(.failure(.decoding(message: "响应缺少 data.limits")))
                    return
                }

                // 订阅等级（planName / level），用于窗口名与诊断。
                let planName = (dataObject["planName"] as? String)
                    ?? (dataObject["level"] as? String)
                    ?? "GLM Coding Plan"

                // 每个 limit 条目 → 一个额度窗口。
                // 排序：5小时(3) 在前、每周(6) 居中、MCP月度(5) 最后——
                // 与智谱官方后台"用量统计"卡片顺序一致（每5小时 / 每周 / MCP每月）。
                // 窗口名语义（实测 + 第三方实现核对）：
                //   TOKENS_LIMIT unit=3 number=5 → "5小时" Token 限额（5h 滚动，重置最快）
                //   TOKENS_LIMIT unit=6 number=1 → "每周" Token 限额
                //   TIME_LIMIT  unit=5             → "MCP 月度" 配额（搜索次数，每月重置）
                var windows: [QuotaWindow] = []
                var remainingPercents: [Double] = []
                for limit in limits {
                    let type = (limit["type"] as? String) ?? ""
                    let unit = Self.int(limit["unit"]) ?? 0
                    let reset = Self.date(limit["nextResetTime"])

                    // 窗口名（与官方后台口径一致）：
                    // - unit=3(number=5) TOKENS_LIMIT = 5小时 Token 限额
                    // - unit=6(number=1) TOKENS_LIMIT = 每周 Token 限额
                    // - unit=5 TIME_LIMIT = MCP 月度配额（搜索次数）
                    let unitName: String
                    switch unit {
                    case 3:  unitName = "5小时"
                    case 5:  unitName = "MCP 月度"
                    case 6:  unitName = "每周"
                    default: unitName = "额度"
                    }
                    let kindName = (type == "TOKENS_LIMIT") ? "Tokens"
                        : (type == "TIME_LIMIT" ? "配额" : "")
                    let windowName = kindName.isEmpty
                        ? "\(planName) \(unitName)"
                        : "\(planName) \(unitName) \(kindName)"

                    // 剩余百分比：TIME_LIMIT 优先用官方 `remaining`（真实剩余值）；
                    // 否则用 100 - percentage（percentage 是「已用」百分比，实测确认）。
                    var remainingPercent: Double? = nil
                    if let remaining = Self.double(limit["remaining"]) {
                        remainingPercent = remaining
                    } else if let used = Self.double(limit["percentage"]) {
                        remainingPercent = max(0, 100 - used)
                    }
                    // 兜底：TIME_LIMIT 用 currentValue/usage 推算。
                    if remainingPercent == nil, type == "TIME_LIMIT" {
                        let current = Self.double(limit["currentValue"])
                        let usage = Self.double(limit["usage"])
                        if let current = current, let usage = usage, usage > 0 {
                            remainingPercent = max(0, 100 - current / usage * 100)
                        }
                    }
                    if let p = remainingPercent { remainingPercents.append(p) }

                    windows.append(QuotaWindow(
                        name: windowName,
                        remainingPercent: remainingPercent,
                        usageCount: Self.double(limit["currentValue"])
                            ?? Self.double(limit["usage"])
                            ?? Self.double(limit["number"]),
                        resetAt: reset))
                }

                // 排序：5小时(3) → 每周(6) → MCP月度(5)，与官方后台卡片顺序一致。
                // `menuSummary` 按数组顺序拼成单行；"5小时"（重置最快、最易触顶）
                // 放第一，让它在被"每周/MCP月度"稀释前一眼可见。
                windows.sort { lhs, rhs in
                    func rank(_ name: String) -> Int {
                        if name.contains("5小时") { return 0 }
                        if name.contains("每周") { return 1 }
                        if name.contains("MCP 月度") { return 2 }
                        return 3
                    }
                    return rank(lhs.name) < rank(rhs.name)
                }

                // 状态：取所有窗口「剩余」百分比的最小值判断（已用尽 → exhausted）。
                let minimum = remainingPercents.min()
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
                    windows: windows,
                    balance: nil,
                    refreshedAt: Date(),
                    message: nil)
                completion(.success(snapshot))
            } catch {
                completion(.failure(.decoding(message: error.localizedDescription)))
            }
        }.resume()
    }

    // MARK: - Parsing helpers

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    /// 解析毫秒/秒时间戳或 ISO 字符串为 Date。
    private static func date(_ value: Any?) -> Date? {
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
        return nil
    }
}
