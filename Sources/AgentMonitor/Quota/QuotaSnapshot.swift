import Foundation

/// 支持的额度供应商。供应商标识稳定，用于 Keychain account 和缓存键。
enum QuotaProviderID: String, CaseIterable {
    case minimax
    case glm
    case deepseek

    var displayName: String {
        switch self {
        case .minimax: return "MiniMax"
        case .glm: return "智谱 GLM"
        case .deepseek: return "DeepSeek"
        }
    }
}

/// 额度快照的产品状态。
enum QuotaState: String {
    case loading
    case unconfigured
    case available
    case warning
    case exhausted
    case unsupported
    case failed

    var label: String {
        switch self {
        case .loading: return "查询中"
        case .unconfigured: return "未配置密钥"
        case .available: return "额度正常"
        case .warning: return "额度偏低"
        case .exhausted: return "额度已用尽"
        case .unsupported: return "官方暂未提供查询接口"
        case .failed: return "查询失败"
        }
    }
}

/// 一个固定或滚动额度窗口，例如 5 小时窗口、周窗口。
struct QuotaWindow {
    let name: String
    /// 剩余百分比，范围 0...100；接口未返回时为 nil。
    let remainingPercent: Double?
    /// 当前窗口用量计数；接口未返回时为 nil。
    let usageCount: Double?
    /// 官方接口返回的恢复时间；接口未返回时为 nil，禁止自行猜测。
    let resetAt: Date?
}

/// 按量付费账户余额。
struct QuotaBalance {
    let currency: String
    let total: Decimal
    let granted: Decimal?
    let toppedUp: Decimal?
    let isAvailable: Bool
}

/// 供应商额度的统一快照。订阅窗口和货币余额可以分别存在，也可以同时存在。
struct QuotaSnapshot {
    let providerID: QuotaProviderID
    let providerName: String
    let state: QuotaState
    let windows: [QuotaWindow]
    let balance: QuotaBalance?
    let refreshedAt: Date
    let message: String?

    static func loading(_ id: QuotaProviderID) -> QuotaSnapshot {
        QuotaSnapshot(providerID: id,
                      providerName: id.displayName,
                      state: .loading,
                      windows: [],
                      balance: nil,
                      refreshedAt: Date(),
                      message: nil)
    }

    static func unconfigured(_ id: QuotaProviderID) -> QuotaSnapshot {
        QuotaSnapshot(providerID: id,
                      providerName: id.displayName,
                      state: .unconfigured,
                      windows: [],
                      balance: nil,
                      refreshedAt: Date(),
                      message: "请在 AI 额度中心配置 API Key")
    }

    static func unsupported(_ id: QuotaProviderID, message: String) -> QuotaSnapshot {
        QuotaSnapshot(providerID: id,
                      providerName: id.displayName,
                      state: .unsupported,
                      windows: [],
                      balance: nil,
                      refreshedAt: Date(),
                      message: message)
    }

    static func failed(_ id: QuotaProviderID, message: String) -> QuotaSnapshot {
        QuotaSnapshot(providerID: id,
                      providerName: id.displayName,
                      state: .failed,
                      windows: [],
                      balance: nil,
                      refreshedAt: Date(),
                      message: message)
    }

    /// 菜单栏中的单行摘要。不会包含 API Key 或原始响应。
    var menuSummary: String {
        if let balance = balance {
            let amount = NSDecimalNumber(decimal: balance.total).stringValue
            let symbol = balance.currency.uppercased() == "CNY" ? "¥" : "\(balance.currency) "
            return "\(state.label) · \(symbol)\(amount)"
        }

        let windowParts = windows.compactMap { window -> String? in
            guard let remaining = window.remainingPercent else { return nil }
            return "\(window.name) \(Int(remaining.rounded()))%"
        }
        if !windowParts.isEmpty {
            return "\(state.label) · \(windowParts.joined(separator: " / "))"
        }
        return message.map { "\(state.label) · \($0)" } ?? state.label
    }
}
