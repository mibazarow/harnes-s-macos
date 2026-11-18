import XCTest
@testable import Harness

/// R35: the launch check is a file lookup, the wording is fixed, and a missing binary
/// becomes a human sentence instead of `command not found`.
final class EnvironmentCheckTests: XCTestCase {
    private func state(_ present: Set<String>) -> EnvironmentState {
        EnvironmentCheck.state { present.contains($0) }
    }

    func testDetectsEachDependencyByItsRealPath() {
        let full = state([
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/opt/homebrew/bin/python3",
            "/opt/homebrew/bin/rg"
        ])
        XCTAssertEqual(full, EnvironmentState(git: true, python3: true, ripgrep: true))

        let bare = state([])
        XCTAssertEqual(bare, EnvironmentState(git: false, python3: false, ripgrep: false))
    }

    func testShimAloneDoesNotCountAsGit() {
        // /usr/bin/git exists on every Mac and only prints the install prompt.
        let shimOnly = state(["/usr/bin/git"])
        XCTAssertFalse(shimOnly.git)
    }

    func testFirstRunReportsMissingAndSecondRunDoesNot() {
        let missing = EnvironmentState(git: false, python3: true, ripgrep: true)
        let first = EnvironmentCheck.notices(current: missing, previous: nil)
        XCTAssertEqual(first.map(\.dependency), [.git])
        XCTAssertTrue(first[0].text.contains("xcode-select --install"))

        let second = EnvironmentCheck.notices(current: missing, previous: missing)
        XCTAssertTrue(second.isEmpty)
    }

    func testPythonIsNotAnnouncedUnprompted() {
        // R35.2: only when a chat really reads an .xlsx, or when asked directly.
        let missing = EnvironmentState(git: true, python3: false, ripgrep: true)
        XCTAssertTrue(EnvironmentCheck.notices(current: missing, previous: nil).isEmpty)
        XCTAssertEqual(
            EnvironmentCheck.notices(current: missing, previous: nil, asked: true)
                .map(\.dependency),
            [.python3]
        )
    }

    func testFlippedStateIsReportedAgain() {
        let missing = EnvironmentState(git: false, python3: true, ripgrep: true)
        let hadGit = EnvironmentState(git: true, python3: true, ripgrep: true)
        XCTAssertEqual(
            EnvironmentCheck.notices(current: missing, previous: hadGit).map(\.dependency),
            [.git]
        )
    }

    func testDirectQuestionShowsFactsEvenWhenUnchanged() {
        let missing = EnvironmentState(git: false, python3: true, ripgrep: true)
        let asked = EnvironmentCheck.notices(current: missing, previous: missing, asked: true)
        XCTAssertEqual(asked.map(\.dependency), [.git])
    }

    func testMessagesAreTheAgreedWording() {
        XCTAssertTrue(
            EnvironmentCheck.message(for: .git).contains("git-инструменты")
        )
        XCTAssertTrue(
            EnvironmentCheck.message(for: .ripgrep).contains("brew install ripgrep")
        )
        XCTAssertTrue(
            EnvironmentCheck.message(for: .python3).contains("openpyxl")
        )
    }

    func testMissingGitBecomesHumanText() {
        let bare = EnvironmentState(git: false, python3: true, ripgrep: true)
        let text = EnvironmentCheck.toolError(
            tool: "git_status", output: "zsh: command not found: git", state: bare
        )
        XCTAssertEqual(text, EnvironmentCheck.message(for: .git))
    }

    func testRealErrorIsNotRewritten() {
        let full = EnvironmentState(git: true, python3: true, ripgrep: true)
        XCTAssertNil(EnvironmentCheck.toolError(
            tool: "git_status", output: "fatal: not a git repository", state: full
        ))
        XCTAssertNil(EnvironmentCheck.toolError(
            tool: "bash", output: "command not found: foo", state: full
        ))
    }

    func testNoticeStoreDoesNotRepeatWithinTheSameState() {
        let suite = UserDefaults(suiteName: "env-check-\(UUID().uuidString)")!
        let store = EnvironmentNoticeStore(defaults: suite)
        let missing = EnvironmentState(git: false, python3: true, ripgrep: true)

        XCTAssertEqual(store.takeNotices(current: missing).count, 1)
        XCTAssertTrue(store.takeNotices(current: missing).isEmpty)

        let restored = EnvironmentState(git: true, python3: true, ripgrep: true)
        XCTAssertTrue(store.takeNotices(current: restored).isEmpty)
        // Appeared then disappeared again: worth one more line.
        XCTAssertEqual(store.takeNotices(current: missing).count, 1)
    }
}
