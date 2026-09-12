import Foundation
import AILimitsCore

/// Task 4, шаг 4: allowlist по точному host И path.
/// Префиксные совпадения не разрешены; query, userinfo, нестандартный порт, http — отказ.
public enum EndpointPolicy {
    /// Разрешённые endpoints: (провайдер, host, path). Расширяется в задачах 8–11.
    private static let allowed: [ProviderID: Set<String>] = [
        .openrouter: ["https://openrouter.ai/api/v1/credits"],
        .kimi: ["https://api.kimi.com/coding/v1/usages"],
        .zai: ["https://api.z.ai/api/monitor/usage/quota/limit"],
        .claude: ["https://api.anthropic.com/api/oauth/usage"]
    ]

    public static func permits(provider: ProviderID, url: URL) -> Bool {
        guard let allowedPaths = allowed[provider] else { return false }
        // Только HTTPS.
        guard url.scheme?.lowercased() == "https" else { return false }
        // Без userinfo (https://key@host).
        guard url.user == nil, url.password == nil else { return false }
        // Без query и fragment.
        guard url.query == nil, url.fragment == nil else { return false }
        // Только стандартный порт 443 (nil = default).
        guard url.port == nil || url.port == 443 else { return false }
        // Точное совпадение scheme+host+path, без префиксных трюков.
        let normalized = url.absoluteString
        return allowedPaths.contains(normalized)
    }
}
