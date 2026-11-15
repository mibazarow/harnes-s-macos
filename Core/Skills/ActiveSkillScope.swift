import Foundation

/// The tool restriction declared by the skill that was read last.
///
/// `allowed-tools` in a manifest used to be parsed and thrown away, so a skill that
/// claimed "I only read files" still had the whole catalog. The scope is session state:
/// it is set by `skill_read`, enforced at call time, and cleared at the start of the
/// next user turn (or by reading a skill without the field).
actor ActiveSkillScope {
    /// Meta tools stay available: without them the agent cannot read the next skill or
    /// report progress, and the restriction would be a trap rather than a boundary.
    static let alwaysAllowed: Set<String> = [
        "skill_list", "skill_read", "todowrite", "todo_read", "app_logs"
    ]

    private var skill: String?
    private var allowed: [String] = []

    var activeSkill: String? { skill }

    func activate(skill name: String, allowedTools: [String]) {
        let patterns = allowedTools
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !patterns.isEmpty else {
            clear()
            return
        }
        skill = name
        allowed = patterns
    }

    func clear() {
        skill = nil
        allowed = []
    }

    func allows(_ tool: String) -> Bool {
        guard skill != nil else { return true }
        let name = tool.lowercased()
        if Self.alwaysAllowed.contains(name) { return true }
        return allowed.contains { pattern in
            if pattern.hasSuffix("*") {
                return name.hasPrefix(String(pattern.dropLast()))
            }
            return name == pattern
        }
    }

    func denialReason(_ tool: String) -> String? {
        guard let skill, !allows(tool) else { return nil }
        return "Инструмент \(tool) не разрешён активным скиллом «\(skill)» "
            + "(allowed-tools: \(allowed.joined(separator: ", "))). "
            + "Дочитай скилл или выбери другой."
    }
}
