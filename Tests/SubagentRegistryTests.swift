import XCTest
@testable import Harness

/// D8: names, depth, capacity and interrupt authority.
final class SubagentRegistryTests: XCTestCase {
    func testChildrenGetUniqueNames() async throws {
        let registry = SubagentRegistry(limit: 4, maxDepth: 2)
        let first = try await registry.begin(parent: SubagentRegistry.root)
        let second = try await registry.begin(parent: SubagentRegistry.root)
        XCTAssertEqual(first.id, "agent-1")
        XCTAssertEqual(second.id, "agent-2")
        XCTAssertEqual(first.depth, 1)
        await registry.end(first.id)
        let third = try await registry.begin(parent: SubagentRegistry.root)
        XCTAssertEqual(third.id, "agent-3", "имена не переиспользуются внутри сессии")
    }

    func testCapacityIsEnforced() async throws {
        let registry = SubagentRegistry(limit: 1, maxDepth: 2)
        _ = try await registry.begin(parent: SubagentRegistry.root)
        do {
            _ = try await registry.begin(parent: SubagentRegistry.root)
            XCTFail("лимит должен отказать")
        } catch {}
        let running = await registry.running
        XCTAssertEqual(running, 1)
    }

    func testDepthIsEnforced() async throws {
        let registry = SubagentRegistry(limit: 4, maxDepth: 1)
        _ = try await registry.begin(parent: SubagentRegistry.root)
        do {
            _ = try await registry.begin(parent: "agent-1")
            XCTFail("глубина 2 при лимите 1 должна отказать")
        } catch {}
    }

    func testAncestorInterruptsOnlyItsDescendants() async throws {
        let registry = SubagentRegistry(limit: 4, maxDepth: 3)
        _ = try await registry.begin(parent: SubagentRegistry.root)
        _ = try await registry.begin(parent: "agent-1")
        _ = try await registry.begin(parent: SubagentRegistry.root)

        let refused = await registry.interrupt(target: "agent-3", by: "agent-1", reason: "чужой")
        XCTAssertTrue(refused.contains("не ваш потомок"), refused)
        let thirdCancelled = await registry.isCancelled("agent-3")
        XCTAssertFalse(thirdCancelled)

        let allowed = await registry.interrupt(target: "agent-2", by: "agent-1", reason: "готово")
        XCTAssertTrue(allowed.contains("прерван"), allowed)
        let secondCancelled = await registry.isCancelled("agent-2")
        XCTAssertTrue(secondCancelled)
    }

    func testUserMayInterruptAnything() async throws {
        let registry = SubagentRegistry()
        _ = try await registry.begin(parent: SubagentRegistry.root)
        _ = await registry.interrupt(target: "agent-1", by: "user", reason: "стоп")
        let cancelled = await registry.isCancelled("agent-1")
        XCTAssertTrue(cancelled)
    }

    func testInterruptingAParentCancelsDescendants() async throws {
        let registry = SubagentRegistry(limit: 4, maxDepth: 3)
        _ = try await registry.begin(parent: SubagentRegistry.root)
        _ = try await registry.begin(parent: "agent-1")
        _ = await registry.interrupt(target: "agent-1", by: "user", reason: "стоп")
        let cancelled = await registry.isCancelled("agent-1")
        XCTAssertTrue(cancelled)
        let secondCancelled = await registry.isCancelled("agent-2")
        XCTAssertTrue(secondCancelled)
    }

    func testUnknownChildIsReported() async {
        let registry = SubagentRegistry()
        let line = await registry.interrupt(target: "agent-9", by: "user", reason: "стоп")
        XCTAssertTrue(line.contains("не найден"), line)
    }
}
