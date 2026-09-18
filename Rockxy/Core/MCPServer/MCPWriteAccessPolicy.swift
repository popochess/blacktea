import Foundation

// MARK: - MCPWriteAccessPolicy

/// Gates the MCP tools that mutate proxy rules.
///
/// Write tools stay off unless the user opts in. An MCP client that can create
/// a Map Local rule can rewrite every response flowing through the proxy, so
/// that capability is deliberately not implied by enabling the MCP server —
/// the upstream tool set is read-only for the same reason.
struct MCPWriteAccessPolicy: Sendable, Equatable {
    // MARK: Lifecycle

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    /// Reads the opt-in flag. An absent key resolves to `false`, so a fresh
    /// install and a failed read both land on the safe value.
    init(defaults: UserDefaults = .standard) {
        isEnabled = defaults.bool(forKey: Self.defaultsKey)
    }

    // MARK: Internal

    /// `UserDefaults` key backing the Settings → MCP toggle.
    static let defaultsKey = "mcpWriteToolsEnabled"

    let isEnabled: Bool
}
