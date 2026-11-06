import Foundation
import GRDB

/// Answers "what project is this?" so the agent stops guessing about stack,
/// build commands and test commands.
struct ProjectInspector: Sendable {
    struct Profile: Sendable {
        var kind: String
        var name: String?
        var php: Bool
        var bitrix: Bool
        var swift: Bool
        var node: Bool
        var python: Bool
        var buildCommand: String?
        var testCommand: String?
        var lintCommand: String?
        var notes: [String]
    }

    let workspace: URL

    func inspect() -> Profile {
        let fm = FileManager.default
        var notes: [String] = []

        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: workspace.appendingPathComponent(name).path)
        }

        let bitrix = exists("bitrix") || exists("local") || exists("upload")
        let php = bitrix
            || exists("composer.json")
            || firstMatch(extension: "php") != nil
        let swift = exists("Package.swift") || exists("project.yml")
            || exists(".xcodeproj") || firstMatch(extension: "swift") != nil
        let node = exists("package.json")
        let python = exists("pyproject.toml") || exists("requirements.txt")

        if bitrix {
            notes.append("Битрикс: код в local/, компоненты в local/components, модули в local/modules")
            if exists("local/php_interface/init.php") {
                notes.append("есть local/php_interface/init.php — события и хелперы")
            }
            if exists("bitrix/php_interface/dbconn.php") {
                notes.append("bitrix/php_interface/dbconn.php содержит креды БД — не выводи их")
            }
        }

        let kind: String = if bitrix {
            "Битрикс"
        } else if swift {
            "Swift"
        } else if node {
            "Node"
        } else if python {
            "Python"
        } else if php {
            "PHP"
        } else {
            "неизвестно"
        }

        return Profile(
            kind: kind,
            name: projectName(),
            php: php,
            bitrix: bitrix,
            swift: swift,
            node: node,
            python: python,
            buildCommand: buildCommand(swift: swift, node: node, bitrix: bitrix),
            testCommand: testCommand(swift: swift, node: node, python: python),
            lintCommand: lintCommand(php: php, swift: swift, node: node, python: python),
            notes: notes
        )
    }

    private func projectName() -> String? {
        let composer = workspace.appendingPathComponent("composer.json")
        if let data = try? Data(contentsOf: composer),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = object["name"] as? String {
            return name
        }
        let package = workspace.appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: package),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = object["name"] as? String {
            return name
        }
        return nil
    }

    private func buildCommand(swift: Bool, node: Bool, bitrix: Bool) -> String? {
        if swift {
            if FileManager.default.fileExists(atPath: workspace.appendingPathComponent("project.yml").path) {
                return "xcodegen generate && xcodebuild -scheme $(ls *.xcodeproj | head -1 | sed 's/.xcodeproj//') build"
            }
            return "swift build"
        }
        if node { return "npm run build" }
        if bitrix { return nil }
        return nil
    }

    private func testCommand(swift: Bool, node: Bool, python: Bool) -> String? {
        if swift { return "swift test" }
        if node { return "npm test" }
        if python { return "pytest -q" }
        return nil
    }

    private func lintCommand(php: Bool, swift: Bool, node: Bool, python: Bool) -> String? {
        if php { return "php -l <file>" }
        if swift { return "swift build" }
        if node { return "npm run lint" }
        if python { return "ruff check ." }
        return nil
    }

    private func firstMatch(extension ext: String, limit: Int = 1) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: workspace,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var found = 0
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == ext {
                found += 1
                if found >= limit { return url }
            }
        }
        return nil
    }

    func render(_ profile: Profile) -> String {
        var lines = [
            "Проект: \(profile.name ?? workspace.lastPathComponent)",
            "Тип: \(profile.kind)",
            "Стек: " + [
                profile.php ? "PHP" : nil,
                profile.bitrix ? "Битрикс" : nil,
                profile.swift ? "Swift" : nil,
                profile.node ? "Node" : nil,
                profile.python ? "Python" : nil
            ].compactMap { $0 }.joined(separator: ", ")
        ]
        if let build = profile.buildCommand { lines.append("Сборка: \(build)") }
        if let test = profile.testCommand { lines.append("Тесты: \(test)") }
        if let lint = profile.lintCommand { lines.append("Линт: \(lint)") }
        if !profile.notes.isEmpty {
            lines.append("Заметки:")
            lines.append(contentsOf: profile.notes.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}