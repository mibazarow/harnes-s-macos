import Foundation

extension ToolRegistry {
    /// R30.4: the agent's own procedures. The model may read them and write them,
    /// because it owns the conversation and the source.
    func skillLearnTool(_ args: [String: Any]) async -> ToolResult {
        let action = (args["action"] as? String)?.lowercased() ?? "list"
        switch action {
        case "list":
            let skills = LearnedSkillStore.list()
            guard !skills.isEmpty else { return .ok("Выученных навыков нет.") }
            return .ok(skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n"))

        case "read":
            guard let name = args["name"] as? String, !name.isEmpty else {
                return .fail("name обязателен")
            }
            guard let skill = LearnedSkillStore.read(name) else {
                return .fail("Навык «\(name)» не найден. Список: skill_learn list.")
            }
            return .ok("\(skill.name)\n\(skill.body)")

        case "save":
            guard currentUserMessage != nil else {
                return .fail("Навык сохраняется только в ходе, начатом сообщением пользователя.")
            }
            guard let name = args["name"] as? String, !name.isEmpty,
                  name.range(of: #"^[a-z0-9][a-z0-9-]{1,63}$"#, options: .regularExpression) != nil else {
                return .fail("name: строчные латинские буквы, цифры и дефис, 2–64 символа.")
            }
            guard let description = args["description"] as? String, !description.isEmpty else {
                return .fail("description обязателен (до \(LearnedSkill.maxDescription) символов).")
            }
            guard let body = args["body"] as? String, !body.isEmpty else {
                return .fail("body обязателен (до \(LearnedSkill.maxBody) символов).")
            }
            guard body.count <= LearnedSkill.maxBody else {
                return .fail("Тело \(body.count) символов, лимит \(LearnedSkill.maxBody).")
            }
            guard description.count <= LearnedSkill.maxDescription else {
                return .fail("Описание \(description.count) символов, лимит \(LearnedSkill.maxDescription).")
            }
            if let existing = LearnedSkillStore.read(name),
               existing.bodyHash != LearnedSkillStore.bodyHash(existing.body) {
                return .fail("Навык «\(name)» правили руками. Перезапись запрещена; "
                    + "попроси пользователя решить.")
            }
            let secrets = (try? await secrets?.list())?.map(\.value) ?? []
            let cleaned: String
            switch LearnedSkillSanitizer.clean(body, secrets: secrets) {
            case .refused(let reason): return .fail(reason)
            case .ok(let text): cleaned = text
            }
            let now = Timestamps.now()
            let existingCreated = LearnedSkillStore.read(name)?.created ?? now
            let skill = LearnedSkill(
                name: name,
                description: description,
                created: existingCreated,
                updated: now,
                source: (args["source_message_id"] as? String) ?? "chat",
                bodyHash: LearnedSkillStore.bodyHash(cleaned),
                body: cleaned
            )
            do {
                try LearnedSkillStore.save(skill)
            } catch {
                return .fail(error.localizedDescription)
            }
            return .ok("Навык сохранён: \(name) (тело \(cleaned.count) символов).")

        case "patch":
            guard let name = args["name"] as? String, !name.isEmpty,
                  let old = args["old"] as? String, !old.isEmpty,
                  let new = args["new"] as? String else {
                return .fail("patch: name, old и new обязательны.")
            }
            guard var skill = LearnedSkillStore.read(name) else {
                return .fail("Навык «\(name)» не найден.")
            }
            guard skill.bodyHash == LearnedSkillStore.bodyHash(skill.body) else {
                return .fail("Навык «\(name)» правили руками. Patch запрещён: попроси пользователя.")
            }
            guard skill.body.contains(old) else {
                return .fail("Точной цитаты для замены нет в теле. Patch меняет одну "
                    + "точную цитату, а не текст по смыслу.")
            }
            let secrets = (try? await secrets?.list())?.map(\.value) ?? []
            let candidate = skill.body.replacingOccurrences(of: old, with: new)
            let cleaned: String
            switch LearnedSkillSanitizer.clean(candidate, secrets: secrets) {
            case .refused(let reason): return .fail(reason)
            case .ok(let text): cleaned = text
            }
            guard cleaned.count <= LearnedSkill.maxBody else {
                return .fail("После замены тело \(cleaned.count) символов, лимит \(LearnedSkill.maxBody).")
            }
            skill = LearnedSkill(
                name: skill.name, description: skill.description, created: skill.created,
                updated: Timestamps.now(), source: skill.source,
                bodyHash: LearnedSkillStore.bodyHash(cleaned), body: cleaned
            )
            do {
                try LearnedSkillStore.save(skill)
            } catch {
                return .fail(error.localizedDescription)
            }
            return .ok("Навык \(name) обновлён.")

        default:
            return .fail("action: save | patch | list | read")
        }
    }
}
