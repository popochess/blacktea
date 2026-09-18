import Foundation
@testable import Rockxy
import Testing

// Tests for the MCP rule-mutation tools. These exercise the real production
// mutation path (`RulePolicyGate` -> `RuleSyncService` -> `RuleStore`) through
// the injectable `RuleSyncService.store` seam pointed at a temp directory, so a
// tool call that reports success really did reach disk.

@Suite(.serialized)
struct MCPRuleMutationServiceTests {
    // MARK: - Write access gate

    @Test("Write tools are hidden while the write gate is disabled")
    @MainActor
    func writeToolsHiddenWhenGateDisabled() {
        let registry = Self.makeRegistry(mutationService: nil)

        let names = registry.listTools().tools.map(\.name)

        #expect(names.count == MCPToolDefinitions.allTools.count)
        #expect(!names.contains("create_map_local_rule"))
        #expect(!names.contains("set_rule_enabled"))
        #expect(!names.contains("delete_rule"))
    }

    @Test("Write tools are listed once the write gate is enabled")
    @MainActor
    func writeToolsListedWhenGateEnabled() {
        let registry = Self.makeRegistry(mutationService: Self.makeService())

        let names = registry.listTools().tools.map(\.name)

        #expect(names.contains("create_map_local_rule"))
        #expect(names.contains("set_rule_enabled"))
        #expect(names.contains("delete_rule"))
        #expect(names.count == MCPToolDefinitions.allTools.count + MCPToolDefinitions.writeTools.count)
    }

    @Test("Calling a write tool while the gate is disabled is refused")
    @MainActor
    func writeToolRefusedWhenGateDisabled() async throws {
        let registry = Self.makeRegistry(mutationService: nil)

        let result = await registry.callTool(
            params: MCPToolCallParams(name: "create_map_local_rule", arguments: [:])
        )

        #expect(result.isError == true)
    }

    @Test("MCPWriteAccessPolicy defaults to disabled when the key is absent")
    func writeAccessDefaultsOff() throws {
        let defaults = try #require(UserDefaults(suiteName: "rockxy.mcp.write.\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        #expect(MCPWriteAccessPolicy(defaults: defaults).isEnabled == false)

        defaults.set(true, forKey: MCPWriteAccessPolicy.defaultsKey)
        #expect(MCPWriteAccessPolicy(defaults: defaults).isEnabled == true)
    }

    // MARK: - create_map_local_rule

    @Test("create_map_local_rule persists an enabled Map Local rule")
    @MainActor
    func createMapLocalRulePersists() async throws {
        try await withRuleHarness {
            let mockFile = try Self.makeTempMockFile()
            defer { try? FileManager.default.removeItem(at: mockFile) }

            let result = await Self.makeService().createMapLocalRule(arguments: [
                "name": .string("Mock serviceProvider"),
                "url_pattern": .string("^https?://[^/]+/v4/merchant/serviceProvider($|[?#])"),
                "file_path": .string(mockFile.path),
            ])

            #expect(result.isError != true)

            let rules = await RuleEngine.shared.allRules
            let created = try #require(rules.first { $0.name == "Mock serviceProvider" })
            #expect(created.isEnabled)
            #expect(created.action.toolCategory == "mapLocal")
            guard case let .mapLocal(filePath, statusCode, _, _, headers) = created.action else {
                Issue.record("Expected a mapLocal action")
                return
            }
            #expect(filePath == mockFile.path)
            #expect(statusCode == 200)
            #expect(headers.contains { $0.name == "Content-Type" && $0.value == "application/json" })

            // The tool must report only durable success, so the rule is on disk too.
            let reloaded = RuleEngine()
            try await reloaded.loadRules(from: RuleSyncService.store)
            #expect(await reloaded.allRules.contains { $0.id == created.id })
        }
    }

    @Test("create_map_local_rule rejects a file path that does not exist")
    @MainActor
    func createMapLocalRuleRejectsMissingFile() async throws {
        try await withRuleHarness {
            let result = await Self.makeService().createMapLocalRule(arguments: [
                "name": .string("Missing file"),
                "url_pattern": .string(".*example\\.com.*"),
                "file_path": .string("/tmp/rockxy-does-not-exist-\(UUID().uuidString).json"),
            ])

            #expect(result.isError == true)
            #expect(await RuleEngine.shared.allRules.isEmpty)
        }
    }

    @Test("create_map_local_rule rejects a url_pattern that is not a valid regex")
    @MainActor
    func createMapLocalRuleRejectsInvalidRegex() async throws {
        try await withRuleHarness {
            let mockFile = try Self.makeTempMockFile()
            defer { try? FileManager.default.removeItem(at: mockFile) }

            let result = await Self.makeService().createMapLocalRule(arguments: [
                "name": .string("Bad regex"),
                "url_pattern": .string("([unclosed"),
                "file_path": .string(mockFile.path),
            ])

            #expect(result.isError == true)
            #expect(await RuleEngine.shared.allRules.isEmpty)
        }
    }

    @Test("create_map_local_rule rejects a status code outside 100...599")
    @MainActor
    func createMapLocalRuleRejectsBadStatusCode() async throws {
        try await withRuleHarness {
            let mockFile = try Self.makeTempMockFile()
            defer { try? FileManager.default.removeItem(at: mockFile) }

            let result = await Self.makeService().createMapLocalRule(arguments: [
                "name": .string("Bad status"),
                "url_pattern": .string(".*example\\.com.*"),
                "file_path": .string(mockFile.path),
                "status_code": .int(999),
            ])

            #expect(result.isError == true)
            #expect(await RuleEngine.shared.allRules.isEmpty)
        }
    }

    // MARK: - set_rule_enabled / delete_rule

    @Test("set_rule_enabled disables an existing rule")
    @MainActor
    func setRuleEnabledDisables() async throws {
        try await withRuleHarness {
            let rule = Self.sampleRule()
            await RuleSyncService.replaceAllRules([rule])

            let result = await Self.makeService().setRuleEnabled(ruleID: rule.id, enabled: false)

            #expect(result.isError != true)
            let stored = try #require(await RuleEngine.shared.allRules.first { $0.id == rule.id })
            #expect(stored.isEnabled == false)
        }
    }

    @Test("delete_rule removes an existing rule")
    @MainActor
    func deleteRuleRemoves() async throws {
        try await withRuleHarness {
            let rule = Self.sampleRule()
            await RuleSyncService.replaceAllRules([rule])

            let result = await Self.makeService().deleteRule(ruleID: rule.id)

            #expect(result.isError != true)
            #expect(await !RuleEngine.shared.allRules.contains { $0.id == rule.id })
        }
    }

    @Test("set_rule_enabled reports an error for an unknown rule id")
    @MainActor
    func setRuleEnabledUnknownID() async throws {
        try await withRuleHarness {
            let result = await Self.makeService().setRuleEnabled(ruleID: UUID(), enabled: true)
            #expect(result.isError == true)
        }
    }

    // MARK: Private

    private static let tempFileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("rockxy-mcp-mutation-tests", isDirectory: true)
        .appendingPathComponent("rules.json")

    private static func makeService() -> MCPRuleMutationService {
        MCPRuleMutationService(ruleEngine: RuleEngine.shared, policyGate: RulePolicyGate())
    }

    @MainActor
    private static func makeRegistry(mutationService: MCPRuleMutationService?) -> MCPToolRegistry {
        let coordinator = MCPServerCoordinator()
        return MCPToolRegistry(
            flowService: MCPFlowQueryService(
                serverCoordinator: coordinator,
                redactionPolicy: MCPRedactionPolicy(isEnabled: false)
            ),
            statusService: MCPStatusService(serverCoordinator: coordinator),
            ruleService: MCPRuleQueryService(ruleEngine: RuleEngine()),
            ruleMutationService: mutationService
        )
    }

    private static func sampleRule() -> ProxyRule {
        ProxyRule(
            name: "Sample",
            matchCondition: RuleMatchCondition(urlPattern: ".*example\\.com.*"),
            action: .block(statusCode: 403)
        )
    }

    private static func makeTempMockFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rockxy-mock-\(UUID().uuidString).json")
        try Data(#"{"centerId":"ben_lee"}"#.utf8).write(to: url)
        return url
    }

    /// Runs `body` under the shared rule-test lock with `RuleSyncService.store`,
    /// the engine's rules, and the load-cache all backed up and restored.
    @MainActor
    private func withRuleHarness(_ body: () async throws -> Void) async throws {
        await RuleTestLock.shared.acquire()
        let storeBackup = RuleSyncService.store
        let engineBackup = await RuleEngine.shared.allRules

        try? FileManager.default.createDirectory(
            at: Self.tempFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: Self.tempFileURL)
        RuleSyncService.store = RuleStore(fileURL: Self.tempFileURL)
        await RuleEngine.shared.replaceAll([])
        await RuleSyncService.resetLoadStateForTesting()

        do {
            try await body()
        } catch {
            await restore(storeBackup: storeBackup, engineBackup: engineBackup)
            throw error
        }
        await restore(storeBackup: storeBackup, engineBackup: engineBackup)
    }

    @MainActor
    private func restore(storeBackup: RuleStore, engineBackup: [ProxyRule]) async {
        RuleSyncService.store = storeBackup
        await RuleEngine.shared.replaceAll(engineBackup)
        await RuleSyncService.resetLoadStateForTesting()
        try? FileManager.default.removeItem(at: Self.tempFileURL)
        await RuleTestLock.shared.release()
    }
}
