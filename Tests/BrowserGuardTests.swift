import XCTest
@testable import Harness

/// R16.6: system pages are refused, and a site that already answered `webfetch` gets a
/// ladder reminder after using the browser for it.
final class BrowserGuardTests: XCTestCase {
    private let context = ToolCallContext(
        workspace: URL(fileURLWithPath: NSTemporaryDirectory()), readOnly: false
    )

    private func browser(_ url: String) -> ToolCall {
        ToolCall(id: "b", name: "browser", arguments: #"{"action":"text","url":"\#(url)"}"#)
    }

    private func fetch(_ url: String) -> ToolCall {
        ToolCall(id: "f", name: "webfetch", arguments: #"{"url":"\#(url)"}"#)
    }

    private func verdict(_ interceptor: BrowserGuardInterceptor, _ call: ToolCall) async throws -> GuardVerdict {
        try await interceptor.beforeCall(call, context: context)
    }

    func testSystemPagesAreRefused() async throws {
        let guardrail = BrowserGuardInterceptor()
        for url in ["chrome://settings", "devtools://devtools/bundled/inspector.html",
                    "chrome-extension://abc/page.html", "about:blank"] {
            switch try await verdict(guardrail, browser(url)) {
            case .deny(_, let guidance):
                XCTAssertTrue(guidance?.contains("http(s)") ?? false, "\(url): \(guidance ?? "nil")")
            default:
                XCTFail("\(url) должен быть отклонён")
            }
        }
    }

    func testRegularPageIsAllowed() async throws {
        switch try await verdict(BrowserGuardInterceptor(), browser("https://example.com/")) {
        case .pass: break
        default: XCTFail("обычный http(s) не блокируется")
        }
    }

    func testLadderIsSilentOnTheFirstBrowserVisit() async {
        let guardrail = BrowserGuardInterceptor()
        let result = await guardrail.afterResult(
            browser("https://example.com/a"), result: .ok("done"), context: context
        )
        XCTAssertEqual(result.output, "done")
    }

    func testLadderRemindsWhenTheSiteWasAlreadyFetchedAsText() async {
        let guardrail = BrowserGuardInterceptor()
        _ = await guardrail.afterResult(
            fetch("https://example.com/a"), result: .ok("text"), context: context
        )
        let result = await guardrail.afterResult(
            browser("https://example.com/b"), result: .ok("done"), context: context
        )
        XCTAssertTrue(result.output.contains("уже отдавался webfetch"), result.output)
        XCTAssertFalse(result.isError, "напоминание не блокирует")
    }

    func testLadderJustifiesTheBrowserAfterA403() async {
        let guardrail = BrowserGuardInterceptor()
        _ = await guardrail.afterResult(
            fetch("https://blocked.example/a"), result: .fail("HTTP 403 для https://blocked.example/a"),
            context: context
        )
        let result = await guardrail.afterResult(
            browser("https://blocked.example/b"), result: .ok("done"), context: context
        )
        XCTAssertTrue(result.output.contains("браузер здесь оправдан"), result.output)
    }

    func testDenialReachesTheModelThroughTheRegistry() async {
        let registry = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil,
            interceptors: ToolInterceptorChain([BrowserGuardInterceptor()])
        )
        let result = await registry.execute(browser("chrome://settings"))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("системная вкладка"), result.output)
    }
}
