import Foundation

actor SkillsService {
    private let userDirectory: URL
    private let builtinDirectory: URL?
    private let loader: SkillLoader
    private let importer: SkillImporter

    init(userDirectory: URL = AppPaths.userSkillsDirectory, builtinDirectory: URL? = SkillsService.defaultBuiltinDirectory) {
        self.userDirectory = userDirectory
        self.builtinDirectory = builtinDirectory
        self.loader = SkillLoader(userDirectory: userDirectory, builtinDirectory: builtinDirectory)
        self.importer = SkillImporter(userDirectory: userDirectory)
    }

    static var defaultBuiltinDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("skills/builtin", isDirectory: true)
    }

    func list() -> [SkillRecord] {
        loader.loadAll()
    }

    func install(from source: String, force: Bool = false) async throws -> SkillRecord {
        try await importer.install(source: source, force: force)
    }

    func remove(name: String) throws {
        guard let record = loader.record(named: name) else {
            throw ConfigurationError.notFound(name)
        }
        guard record.scope == .user else {
            throw ConfigurationError.builtinReadOnly(record.name)
        }
        try importer.remove(name: record.name)
    }

    func setEnabled(name: String, enabled: Bool) throws {
        guard let record = loader.record(named: name) else {
            throw ConfigurationError.notFound(name)
        }
        guard record.scope == .user else {
            throw ConfigurationError.builtinReadOnly(record.name)
        }
        try importer.setEnabled(name: record.name, enabled: enabled)
    }
}