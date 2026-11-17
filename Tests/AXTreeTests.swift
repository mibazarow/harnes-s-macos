import XCTest
@testable import Harness

/// R18.2/R18.8: tree rendering, search and the System Settings guard are deterministic.
final class AXTreeTests: XCTestCase {
    private var tree: AXNode {
        AXNode(
            role: "AXWindow", title: "Настройки", value: "", identifier: "", position: .zero,
            size: CGSize(width: 800, height: 600), enabled: true, path: [],
            children: [
                AXNode(
                    role: "AXButton", title: "Конфиденциальность", value: "", identifier: "privacy",
                    position: CGPoint(x: 10, y: 20), size: CGSize(width: 100, height: 30),
                    enabled: true, path: [0], children: []
                ),
                AXNode(
                    role: "AXStaticText", title: "", value: "Версия 15.0", identifier: "",
                    position: CGPoint(x: 10, y: 60), size: CGSize(width: 200, height: 20),
                    enabled: true, path: [1], children: []
                )
            ]
        )
    }

    func testTreeRendersPathsAndFrames() {
        var budget = 100
        let lines = tree.lines(depth: 0, maxNodes: 100, budget: &budget)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("AXWindow"), lines[0])
        XCTAssertTrue(lines[1].contains("[0] AXButton «Конфиденциальность»"), lines[1])
        XCTAssertTrue(lines[1].contains("center") == false)
        XCTAssertTrue(lines[1].contains("10,20"), lines[1])
    }

    func testSearchFindsByValueAndIdentifier() {
        var budget = 100
        XCTAssertEqual(tree.search("Версия", regex: false, limit: 10, budget: &budget).first?.path, [1])
        XCTAssertEqual(tree.search("privacy", regex: false, limit: 10, budget: &budget).first?.path, [0])
        XCTAssertEqual(tree.search("Конфиденц.*", regex: true, limit: 10, budget: &budget).first?.path, [0])
        XCTAssertTrue(tree.search("[", regex: true, limit: 10, budget: &budget).isEmpty)
    }

    func testGuardRefusesSystemSettingsClickWithoutConfirmation() async throws {
        let guardrail = SystemUIGuardInterceptor()
        let call = ToolCall(
            id: "1", name: "ui",
            arguments: #"{"action":"click","app":"System Settings","path":[0]}"#
        )
        let verdict = try await guardrail.beforeCall(
            call, context: ToolCallContext(workspace: URL(fileURLWithPath: "/tmp"), readOnly: false)
        )
        switch verdict {
        case .deny(let reason, let guidance):
            XCTAssertTrue(reason.contains("Системных настройках"), reason)
            XCTAssertTrue(guidance?.contains("confirm: true") ?? false, guidance ?? "")
        default:
            XCTFail("клик по Системным настройкам должен требовать confirm")
        }
    }

    func testGuardAllowsConfirmedAndOrdinaryApps() async throws {
        let guardrail = SystemUIGuardInterceptor()
        for arguments in [
            #"{"action":"click","app":"System Settings","path":[0],"confirm":true}"#,
            #"{"action":"click","app":"TextEdit","path":[0]}"#
        ] {
            let verdict = try await guardrail.beforeCall(
                ToolCall(id: "1", name: "ui", arguments: arguments),
                context: ToolCallContext(workspace: URL(fileURLWithPath: "/tmp"), readOnly: false)
            )
            if case .deny = verdict { XCTFail("не должен блокировать: \(arguments)") }
        }
    }
}
