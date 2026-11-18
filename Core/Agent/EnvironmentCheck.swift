import Foundation

/// What this machine has, checked without launching anything (R35).
///
/// The check must stay free of `Process`: it runs once per launch on the UI path, and
/// spawning `which` three times to answer a yes/no question is exactly the kind of
/// startup work that makes a first paint feel slow. Fixed paths are enough because
/// macOS installs these in predictable places, and a wrong "missing" is harmless —
/// the warning is a courtesy, not a gate.
struct EnvironmentState: Sendable, Equatable {
    var git: Bool
    var python3: Bool
    var ripgrep: Bool

    subscript(_ dependency: EnvironmentCheck.Dependency) -> Bool {
        switch dependency {
        case .git: git
        case .python3: python3
        case .ripgrep: ripgrep
        }
    }
}

enum EnvironmentCheck {
    enum Dependency: String, CaseIterable, Sendable {
        case git
        case python3
        case ripgrep

        /// Name as it appears in the message and in the tool error.
        var title: String {
            switch self {
            case .git: "git"
            case .python3: "python3"
            case .ripgrep: "ripgrep"
            }
        }

        var isRequired: Bool { self == .git }
    }

    /// Paths that prove a working binary, not the `/usr/bin` shim: on a Mac without
    /// Command Line Tools `/usr/bin/git` exists and only prints the install prompt, so
    /// its presence would hide the very problem this check reports.
    static let searchPaths: [Dependency: [String]] = [
        .git: [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git"
        ],
        .python3: [
            "/Library/Developer/CommandLineTools/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3"
        ],
        .ripgrep: [
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "/usr/bin/rg"
        ]
    ]

    /// `exists` is injectable so the test does not depend on the machine it runs on.
    static func state(
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> EnvironmentState {
        func has(_ dependency: Dependency) -> Bool {
            (searchPaths[dependency] ?? []).contains(where: exists)
        }
        return EnvironmentState(git: has(.git), python3: has(.python3), ripgrep: has(.ripgrep))
    }

    /// Wording is fixed by the task: it is what a person on a clean Mac reads.
    static func message(for dependency: Dependency) -> String {
        switch dependency {
        case .git:
            "На этой машине не установлены Xcode Command Line Tools, поэтому git-инструменты "
                + "(status, diff, log, commit) недоступны. Если они нужны — открой Терминал и "
                + "выполни `xcode-select --install`, потом согласись с системным диалогом. "
                + "Остальное работает и без них."
        case .python3:
            "Для чтения xlsx нужен python3 с openpyxl; без него таблицы читаются упрощённо. "
                + "Установка: `xcode-select --install` (или python3 с python.org)."
        case .ripgrep:
            "Не найден ripgrep — поиск по коду работает через grep, просто медленнее. "
                + "Установка: `brew install ripgrep`."
        }
    }

    /// One line per dependency that is missing now and was not reported before, or whose
    /// state flipped (R35.3). `asked` is a direct question from the user: then the facts
    /// are shown even when nothing changed.
    static func notices(
        current: EnvironmentState,
        previous: EnvironmentState?,
        asked: Bool = false
    ) -> [(dependency: Dependency, text: String)] {
        Dependency.allCases.compactMap { dependency in
            guard !current[dependency] else { return nil }
            // R35.2: python3 is announced only when it is actually needed — a chat that
            // never opens an .xlsx has no reason to hear about it.
            if dependency == .python3, !asked { return nil }
            if asked { return (dependency, message(for: dependency)) }
            // No memory of a previous run: report once. With memory, report only a
            // change from "present" to "missing"; a still-missing dependency stays quiet.
            guard let previous else { return (dependency, message(for: dependency)) }
            return previous[dependency] ? (dependency, message(for: dependency)) : nil
        }
    }

    /// R35.4: a tool that hit a missing binary answers with the same human text, not the
    /// shell's `command not found`. Returns nil when the output is a real error.
    static func toolError(tool: String, output: String, state: EnvironmentState) -> String? {
        let lower = output.lowercased()
        let missing = lower.contains("command not found")
            || lower.contains("not found in $path")
            || lower.contains("no such file or directory")
        guard missing else { return nil }

        switch tool {
        case "git", "git_status", "git_diff", "git_log", "git_commit", "git_stash":
            guard !state.git else { return nil }
            return message(for: .git)
        case "search_code", "fs_grep":
            guard !state.ripgrep else { return nil }
            return message(for: .ripgrep) + "\nЭто необязательная зависимость: поиск уже "
                + "переключён на grep."
        case "doc_read":
            guard !state.python3 else { return nil }
            return message(for: .python3)
        default:
            return nil
        }
    }
}

/// Remembers what was already reported so the same warning does not greet the user on
/// every launch (R35.3). Reset with the rest of the app settings.
final class EnvironmentNoticeStore: @unchecked Sendable {
    private static let prefix = "env.notice.reported."
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func lastReported() -> EnvironmentState? {
        lock.lock(); defer { lock.unlock() }
        guard defaults.object(forKey: Self.prefix + Dependency.git.rawValue) != nil else {
            return nil
        }
        func read(_ dependency: Dependency) -> Bool {
            defaults.bool(forKey: Self.prefix + dependency.rawValue)
        }
        return EnvironmentState(
            git: read(.git), python3: read(.python3), ripgrep: read(.ripgrep)
        )
    }

    func remember(_ state: EnvironmentState) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(state.git, forKey: Self.prefix + Dependency.git.rawValue)
        defaults.set(state.python3, forKey: Self.prefix + Dependency.python3.rawValue)
        defaults.set(state.ripgrep, forKey: Self.prefix + Dependency.ripgrep.rawValue)
    }

    private typealias Dependency = EnvironmentCheck.Dependency

    /// Notices to show now, and the store is updated so they are not repeated.
    func takeNotices(current: EnvironmentState, asked: Bool = false) -> [String] {
        let lines = EnvironmentCheck.notices(
            current: current, previous: lastReported(), asked: asked
        ).map(\.text)
        remember(current)
        return lines
    }
}
