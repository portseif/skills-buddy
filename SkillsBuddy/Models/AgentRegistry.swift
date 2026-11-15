//
//  AgentRegistry.swift
//  SkillsBuddy
//
//  The coding agents the `skills` CLI supports: display name, `--agent` key,
//  and global skills folder. Generated from the CLI's docs/agents.md by
//  scripts/generate-agent-registry.py into Resources/Agents.json.
//

import Foundation

nonisolated struct AgentDefinition: Codable, Hashable, Sendable, Identifiable {
    /// The `--agent` value (`claude-code`).
    let key: String
    /// What the CLI prints (`Claude Code`).
    let displayName: String
    /// `~/.claude/skills/`; nil for project-only agents.
    let globalSkillsPath: String?
    /// The site whose icon is the agent's logo (`claude.ai`); nil shows initials.
    let homepage: String?

    var id: String { key }

    /// Where this agent keeps a global skill named `skillName`.
    func skillFolderURL(named skillName: String, homeDirectoryURL: URL) -> URL? {
        guard let globalSkillsPath else { return nil }
        let relativePath = globalSkillsPath.hasPrefix("~/") ? String(globalSkillsPath.dropFirst(2)) : globalSkillsPath
        let baseURL = globalSkillsPath.hasPrefix("/") ? URL(fileURLWithPath: globalSkillsPath) : homeDirectoryURL.appending(path: relativePath, directoryHint: .isDirectory)
        return baseURL.appending(path: skillName, directoryHint: .isDirectory)
    }
}

nonisolated enum AgentRegistry {
    static let all: [AgentDefinition] = {
        guard let url = Bundle.main.url(forResource: "Agents", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let agents = try? JSONDecoder().decode([AgentDefinition].self, from: data) else { return [] }
        return agents
    }()

    static func definition(displayName: String) -> AgentDefinition? {
        all.first { $0.displayName == displayName }
    }

    static func definition(key: String) -> AgentDefinition? {
        all.first { $0.key == key }
    }
}

/// One agent a skill is installed for, and where that agent's copy lives.
nonisolated struct SkillAgentInstall: Hashable, Sendable {
    let displayName: String
    /// Nil when the registry doesn't know the agent (a newer CLI than the bundled list).
    let key: String?
    let folderURL: URL?
}
