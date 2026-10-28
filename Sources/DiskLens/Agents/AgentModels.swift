import Foundation

/// A model the user can pick for an agent.
struct ModelChoice: Identifiable, Hashable {
    /// What the CLI takes: an alias for Claude Code, a slug for Codex.
    let id: String
    let name: String
    let note: String
    /// Reasoning levels this model accepts, lowest first.
    let efforts: [String]
    let defaultEffort: String
}

/// Model and reasoning level for the next turn.
struct AgentSettings: Equatable {
    var model: String
    var effort: String
}

extension AgentKind {
    /// Choices for the picker. The user's own default comes first even when the
    /// CLI's list doesn't know it. Read from disk once per launch.
    @MainActor
    func models() -> [ModelChoice] {
        if let cached = Self.modelCache[self] { return cached }
        let list = loadModels()
        Self.modelCache[self] = list
        return list
    }

    @MainActor private static var modelCache: [AgentKind: [ModelChoice]] = [:]

    private func loadModels() -> [ModelChoice] {
        switch self {
        case .claude:
            // Aliases always resolve to the latest version of each family.
            let efforts = ["low", "medium", "high", "xhigh", "max"]
            return [
                ModelChoice(id: "fable", name: "Fable", note: "", efforts: efforts, defaultEffort: "high"),
                ModelChoice(id: "opus", name: "Opus", note: "", efforts: efforts, defaultEffort: "high"),
                ModelChoice(id: "sonnet", name: "Sonnet", note: "", efforts: efforts, defaultEffort: "high"),
                ModelChoice(id: "haiku", name: "Haiku", note: "", efforts: efforts, defaultEffort: "medium"),
            ]
        case .codex:
            // Only what the account's catalog offers: a model named in the user's
            // config but missing here is refused ("not supported when using Codex
            // with a ChatGPT account").
            return Self.codexCachedModels()
        }
    }

    /// What the user runs this agent with outside DiskLens, as the starting choice.
    /// The sidebar ignores the user's settings files, so it has to be explicit.
    @MainActor
    var userDefaults: AgentSettings {
        let choices = models()
        switch self {
        case .claude:
            let settings = Self.json(at: ".claude/settings.json")
            let model = (settings?["model"] as? String).flatMap { m in
                choices.first { m.lowercased().contains($0.id) }?.id
            } ?? "opus"
            return AgentSettings(model: model, effort: settings?["effortLevel"] as? String ?? "high")
        case .codex:
            let config = Self.codexUserConfig()
            let model = config.model.flatMap { m in choices.contains { $0.id == m } ? m : nil }
                ?? choices.first?.id ?? ""
            let fallback = choices.first { $0.id == model }?.defaultEffort ?? "medium"
            return AgentSettings(model: model, effort: config.effort ?? fallback)
        }
    }

    @MainActor
    func modelName(_ id: String) -> String {
        models().first { $0.id == id }?.name ?? id
    }

    // MARK: - Sources

    private static func json(at relativePath: String) -> [String: Any]? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Models Codex itself lists, from the cache it keeps of its model catalog.
    private static func codexCachedModels() -> [ModelChoice] {
        let models = json(at: ".codex/models_cache.json")?["models"] as? [[String: Any]] ?? []
        return models
            .filter { $0["visibility"] as? String == "list" }
            .sorted { ($0["priority"] as? Int ?? 99) < ($1["priority"] as? Int ?? 99) }
            .compactMap { m in
                guard let slug = m["slug"] as? String else { return nil }
                let efforts = (m["supported_reasoning_levels"] as? [[String: Any]] ?? [])
                    .compactMap { $0["effort"] as? String }
                return ModelChoice(id: slug,
                                   name: m["display_name"] as? String ?? slug,
                                   note: m["description"] as? String ?? "",
                                   efforts: efforts.isEmpty ? ["low", "medium", "high"] : efforts,
                                   defaultEffort: m["default_reasoning_level"] as? String ?? "medium")
            }
    }

    /// `model` and `model_reasoning_effort` from ~/.codex/config.toml (top-level keys).
    private static func codexUserConfig() -> (model: String?, effort: String?) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (nil, nil) }
        var model: String?, effort: String?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("[") { break }   // past the top-level table
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if parts[0] == "model" { model = value }
            if parts[0] == "model_reasoning_effort" { effort = value }
        }
        return (model, effort)
    }
}
