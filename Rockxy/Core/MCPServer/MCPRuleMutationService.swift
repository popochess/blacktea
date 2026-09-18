import Foundation
import os

nonisolated(unsafe) private let mcpRuleMutationLogger = Logger(
    subsystem: RockxyIdentity.current.logSubsystem,
    category: "MCPRuleMutationService"
)

// MARK: - MCPRuleMutationService

/// Backs the MCP tools that create, toggle, and delete proxy rules.
///
/// Every mutation routes through ``RulePolicyGate`` — the same seam the rule
/// editing UI uses — so per-category quotas and durable persistence behave
/// identically whether a rule came from a window or from an MCP client. A tool
/// reports success only once the change reached disk.
struct MCPRuleMutationService {
    // MARK: Lifecycle

    init(
        ruleEngine: RuleEngine,
        policyGate: RulePolicyGate = .shared,
        fileManager: FileManager = .default
    ) {
        self.ruleEngine = ruleEngine
        self.policyGate = policyGate
        self.fileManager = fileManager
    }

    // MARK: Internal

    let ruleEngine: RuleEngine
    let policyGate: RulePolicyGate
    let fileManager: FileManager

    // MARK: - create_map_local_rule

    func createMapLocalRule(arguments: [String: MCPJSONValue]) async -> MCPToolCallResult {
        let rule: ProxyRule
        switch buildMapLocalRule(from: arguments) {
        case let .failure(error):
            return errorResult(error.message, param: error.param)
        case let .success(built):
            rule = built
        }

        let outcome = await policyGate.addRulePersisting(rule)
        switch outcome {
        case .quotaExceeded:
            return errorResult(
                "Rule quota reached for mapLocal (max \(policyGate.policy.maxActiveRulesPerTool) active rules "
                    + "per tool). Disable or delete an existing Map Local rule first.",
                param: nil
            )
        case let .loadFailed(message):
            return errorResult("Existing rules could not be loaded, so nothing was changed: \(message)", param: nil)
        case let .persisted(.failed(message)):
            return errorResult("Rule was applied in memory but could not be saved: \(message)", param: nil)
        case .persisted(.saved):
            mcpRuleMutationLogger.info("Created Map Local rule via MCP: \(rule.id.uuidString, privacy: .public)")
            return jsonResult(.object([
                "created": .bool(true),
                "rule": ruleSummary(rule),
            ]))
        }
    }

    // MARK: - set_rule_enabled

    func setRuleEnabled(ruleID: UUID, enabled: Bool) async -> MCPToolCallResult {
        guard let existing = await rule(with: ruleID) else {
            return errorResult("No rule found with id \(ruleID.uuidString)", param: "rule_id")
        }

        let accepted = await policyGate.setRuleEnabled(id: ruleID, enabled: enabled)
        guard accepted else {
            return errorResult(
                "Cannot enable rule — quota reached for \(existing.action.toolCategory) "
                    + "(max \(policyGate.policy.maxActiveRulesPerTool) active rules per tool).",
                param: nil
            )
        }

        guard let updated = await rule(with: ruleID) else {
            return errorResult("Rule \(ruleID.uuidString) disappeared while being updated", param: "rule_id")
        }
        mcpRuleMutationLogger.info("Set rule enabled via MCP: \(ruleID.uuidString, privacy: .public)")
        return jsonResult(.object([
            "updated": .bool(true),
            "rule": ruleSummary(updated),
        ]))
    }

    // MARK: - delete_rule

    func deleteRule(ruleID: UUID) async -> MCPToolCallResult {
        guard let existing = await rule(with: ruleID) else {
            return errorResult("No rule found with id \(ruleID.uuidString)", param: "rule_id")
        }

        await policyGate.removeRule(id: ruleID)

        guard await rule(with: ruleID) == nil else {
            return errorResult("Rule \(ruleID.uuidString) could not be removed", param: "rule_id")
        }
        mcpRuleMutationLogger.info("Deleted rule via MCP: \(ruleID.uuidString, privacy: .public)")
        return jsonResult(.object([
            "deleted": .bool(true),
            "rule": ruleSummary(existing),
        ]))
    }

    // MARK: Private

    /// A rejected argument, carrying the message and the offending parameter name.
    private struct ArgumentError: Error {
        let message: String
        let param: String?
    }

    private func rule(with id: UUID) async -> ProxyRule? {
        await ruleEngine.allRules.first { $0.id == id }
    }

    // MARK: - Validation

    /// Validates every argument before any state changes, so a rejected call
    /// leaves the rule set untouched.
    private func buildMapLocalRule(
        from arguments: [String: MCPJSONValue]
    )
        -> Result<ProxyRule, ArgumentError>
    {
        guard case let .string(name) = arguments["name"], !name.trimmed.isEmpty else {
            return .failure(ArgumentError(message: "Missing required parameter: name", param: "name"))
        }
        guard case let .string(rawPattern) = arguments["url_pattern"], !rawPattern.trimmed.isEmpty else {
            return .failure(ArgumentError(message: "Missing required parameter: url_pattern", param: "url_pattern"))
        }
        guard case let .string(rawFilePath) = arguments["file_path"], !rawFilePath.trimmed.isEmpty else {
            return .failure(ArgumentError(message: "Missing required parameter: file_path", param: "file_path"))
        }

        let matchType: RuleMatchType
        switch arguments["match_type"] {
        case .none:
            matchType = .regex
        case let .string(raw):
            guard let parsed = Self.matchType(fromToolValue: raw) else {
                return .failure(ArgumentError(
                    message: "match_type must be \"regex\" or \"wildcard\"",
                    param: "match_type"
                ))
            }
            matchType = parsed
        default:
            return .failure(ArgumentError(message: "match_type must be a string", param: "match_type"))
        }

        // Only a regex pattern is compiled as-is; a wildcard pattern is escaped
        // by `RulePatternBuilder` and cannot be invalid.
        if matchType == .regex, case let .failure(error) = RegexValidator.compile(rawPattern) {
            return .failure(ArgumentError(
                message: "url_pattern is not a valid regex: \(error.localizedDescription)",
                param: "url_pattern"
            ))
        }

        let filePath = (rawFilePath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: filePath, isDirectory: &isDirectory) else {
            return .failure(ArgumentError(
                message: "file_path does not exist: \(filePath)",
                param: "file_path"
            ))
        }

        var statusCode = 200
        if let raw = arguments["status_code"] {
            guard case let .int(value) = raw, (100 ... 599).contains(value) else {
                return .failure(ArgumentError(
                    message: "status_code must be an integer in 100...599",
                    param: "status_code"
                ))
            }
            statusCode = value
        }

        var delayMs = 0
        if let raw = arguments["delay_ms"] {
            guard case let .int(value) = raw, value >= 0 else {
                return .failure(ArgumentError(message: "delay_ms must be a non-negative integer", param: "delay_ms"))
            }
            delayMs = value
        }

        var method: String?
        if let raw = arguments["method"] {
            guard case let .string(value) = raw, !value.trimmed.isEmpty else {
                return .failure(ArgumentError(message: "method must be a non-empty string", param: "method"))
            }
            method = value.trimmed.uppercased()
        }

        var contentType = Self.defaultContentType
        if let raw = arguments["content_type"] {
            guard case let .string(value) = raw, !value.trimmed.isEmpty else {
                return .failure(ArgumentError(
                    message: "content_type must be a non-empty string",
                    param: "content_type"
                ))
            }
            contentType = value.trimmed
        }

        var isEnabled = true
        if let raw = arguments["enabled"] {
            guard case let .bool(value) = raw else {
                return .failure(ArgumentError(message: "enabled must be a boolean", param: "enabled"))
            }
            isEnabled = value
        }

        // A directory mapping serves files by request path, so it carries no
        // single Content-Type of its own.
        let responseHeaders = isDirectory.boolValue
            ? []
            : [HTTPHeader(name: "Content-Type", value: contentType)]

        return .success(ProxyRule(
            name: name.trimmed,
            isEnabled: isEnabled,
            matchCondition: RuleMatchCondition(
                urlPattern: rawPattern,
                sourceURLPattern: rawPattern,
                method: method,
                matchType: matchType,
                includeSubpaths: false
            ),
            action: .mapLocal(
                filePath: filePath,
                statusCode: statusCode,
                isDirectory: isDirectory.boolValue,
                delayMs: delayMs,
                responseHeaders: responseHeaders
            )
        ))
    }

    private static let defaultContentType = "application/json"

    private static func matchType(fromToolValue raw: String) -> RuleMatchType? {
        switch raw.trimmed.lowercased() {
        case "regex":
            .regex
        case "wildcard":
            .wildcard
        default:
            nil
        }
    }

    // MARK: - Result shaping

    private func ruleSummary(_ rule: ProxyRule) -> MCPJSONValue {
        .object([
            "id": .string(rule.id.uuidString),
            "name": .string(rule.name),
            "is_enabled": .bool(rule.isEnabled),
            "action_type": .string(rule.action.toolCategory),
            "action_summary": .string(rule.action.matchedRuleActionSummary),
        ])
    }

    private func jsonResult(_ value: MCPJSONValue) -> MCPToolCallResult {
        do {
            let data = try value.encodeToData()
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return MCPToolCallResult(content: [.text(text)], isError: nil)
        } catch {
            mcpRuleMutationLogger.error("Failed to encode tool result: \(error.localizedDescription, privacy: .public)")
            return MCPToolCallResult(
                content: [.text(#"{"error": "Internal encoding error"}"#)],
                isError: true
            )
        }
    }

    private func errorResult(_ message: String, param: String?) -> MCPToolCallResult {
        mcpRuleMutationLogger.warning("Rule mutation rejected: \(message, privacy: .public)")
        var payload: [String: MCPJSONValue] = ["error": .string(message)]
        if let param {
            payload["param"] = .string(param)
        }
        return MCPToolCallResult(content: [.text(encodeErrorJSON(payload))], isError: true)
    }

    private func encodeErrorJSON(_ payload: [String: MCPJSONValue]) -> String {
        do {
            let data = try MCPJSONValue.object(payload).encodeToData()
            return String(data: data, encoding: .utf8) ?? #"{"error":"Internal encoding error"}"#
        } catch {
            return #"{"error":"Internal encoding error"}"#
        }
    }
}

// MARK: - String trimming

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
