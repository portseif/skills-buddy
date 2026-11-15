//
//  SkillLockFile.swift
//  SkillsBuddy
//
//  `~/.agents/.skill-lock.json`, written by the `skills` CLI (vercel-labs/skills).
//  Only the fields this app reads; the CLI owns the file and we never write it.
//

import Foundation

nonisolated struct SkillLockFile: Decodable, Sendable {
    let version: Int?
    let skills: [String: SkillLockEntry]
    /// The `--agent` keys picked in the CLI's last interactive install.
    let lastSelectedAgents: [String]?

    static func load(from fileURL: URL) throws -> SkillLockFile {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.makeSkillLockDecoder().decode(SkillLockFile.self, from: data)
    }
}

nonisolated struct SkillLockEntry: Decodable, Hashable, Sendable {
    /// `owner/repo` for GitHub sources.
    let source: String
    /// `github`, `git`, `local`, `well-known`, …
    let sourceType: String?
    let sourceUrl: String?
    /// Branch, tag or commit from a `source#ref` install; nil follows the default branch.
    let ref: String?
    /// Path to the skill's SKILL.md inside the source repo.
    let skillPath: String?
    /// Git tree SHA of the skill folder at install time; empty when untracked.
    let skillFolderHash: String?
    let installedAt: Date?
    let updatedAt: Date?

    /// `skills check` skips entries without a folder hash or skill path (see the
    /// CLI's `getSkipReason`), so they can never report an update.
    var supportsUpdateCheck: Bool {
        !(skillFolderHash ?? "").isEmpty && !(skillPath ?? "").isEmpty
    }

    /// The skill's folder inside the source repo, as the CLI derives it
    /// (`deriveSkillFolder`): `skills/find-skills/SKILL.md` → `skills/find-skills`.
    var skillFolderPath: String? {
        guard var folder = skillPath else { return nil }
        if folder.lowercased().hasSuffix("/skill.md") {
            folder.removeLast(9)
        } else if folder.lowercased().hasSuffix("skill.md") {
            folder.removeLast(8)
        }
        if folder.hasSuffix("/") { folder.removeLast() }
        return folder
    }
}

extension JSONDecoder {
    /// ISO 8601 with fractional seconds, as the CLI writes (`2026-04-27T15:22:03.847Z`).
    nonisolated static func makeSkillLockDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(text, strategy: .iso8601) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(text)")
        }
        return decoder
    }
}
