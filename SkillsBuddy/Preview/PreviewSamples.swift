//
//  PreviewSamples.swift
//  SkillsBuddy
//
//  Generic sample data for #Previews. Debug builds only.
//

#if DEBUG
import Foundation

extension SkillAgentInstall {
    static func preview(_ displayName: String, key: String, folder: URL?) -> SkillAgentInstall {
        SkillAgentInstall(displayName: displayName, key: key, folderURL: folder)
    }
}

extension Skill {
    static let previewSamples: [Skill] = {
        let home = URL(fileURLWithPath: "/Users/example")
        let claudeFolder = home.appending(path: ".claude/skills")
        let sharedFolder = home.appending(path: ".agents/skills")
        let cursorFolder = home.appending(path: ".cursor/skills")
        return [
            Skill(
                folderName: "release-notes",
                displayName: "release-notes",
                summary: "Drafts release notes from merged pull requests and groups them by area.",
                folderURL: sharedFolder.appending(path: "release-notes"),
                resolvedFolderURL: sharedFolder.appending(path: "release-notes"),
                sourceKind: .skillsCLI,
                repository: SkillRepository(location: "example-org/agent-skills"),
                installedAt: .now.addingTimeInterval(-86_400 * 40),
                updatedAt: .now.addingTimeInterval(-86_400 * 3),
                agents: [
                    .preview("Claude Code", key: "claude-code", folder: claudeFolder.appending(path: "release-notes")),
                    .preview("Codex", key: "codex", folder: sharedFolder.appending(path: "release-notes")),
                    .preview("Cursor", key: "cursor", folder: cursorFolder.appending(path: "release-notes")),
                ],
                pluginIdentifier: nil,
                version: "a1b2c3d",
                gitWorkTreeURL: nil,
                isUpdateTracked: true,
                sourceFolderPath: "skills/release-notes",
                installedTreeHash: "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
                pinnedRevision: nil
            ),
            Skill(
                folderName: "api-style-guide",
                displayName: "api-style-guide",
                summary: "Reviews REST endpoints against the team's naming and pagination rules.",
                folderURL: claudeFolder.appending(path: "api-style-guide"),
                resolvedFolderURL: claudeFolder.appending(path: "api-style-guide"),
                sourceKind: .git,
                repository: SkillRepository(location: "https://github.com/example-org/api-style-guide.git"),
                installedAt: .now.addingTimeInterval(-86_400 * 90),
                updatedAt: .now.addingTimeInterval(-86_400 * 12),
                agents: [.preview("Claude Code", key: "claude-code", folder: claudeFolder.appending(path: "api-style-guide"))],
                pluginIdentifier: nil,
                version: "9f8e7d6",
                gitWorkTreeURL: claudeFolder.appending(path: "api-style-guide"),
                isUpdateTracked: true,
                sourceFolderPath: "",
                installedTreeHash: nil,
                pinnedRevision: nil
            ),
            Skill(
                folderName: "meeting-notes",
                displayName: "meeting-notes",
                summary: "Turns a transcript into decisions, owners and follow-ups.",
                folderURL: claudeFolder.appending(path: "meeting-notes"),
                resolvedFolderURL: claudeFolder.appending(path: "meeting-notes"),
                sourceKind: .local,
                repository: nil,
                installedAt: .now.addingTimeInterval(-86_400 * 7),
                updatedAt: .now.addingTimeInterval(-3_600 * 5),
                agents: [
                    .preview("Claude Code", key: "claude-code", folder: claudeFolder.appending(path: "meeting-notes")),
                    .preview("Cursor", key: "cursor", folder: cursorFolder.appending(path: "meeting-notes")),
                ],
                pluginIdentifier: nil,
                version: nil,
                gitWorkTreeURL: nil,
                isUpdateTracked: false,
                sourceFolderPath: nil,
                installedTreeHash: nil,
                pinnedRevision: nil
            ),
            Skill(
                folderName: "chart-builder",
                displayName: "chart-builder",
                summary: "Builds accessible charts with a consistent palette.",
                folderURL: home.appending(path: ".claude/plugins/cache/example-market/charts/1.2.0/skills/chart-builder"),
                resolvedFolderURL: home.appending(path: ".claude/plugins/cache/example-market/charts/1.2.0/skills/chart-builder"),
                sourceKind: .plugin,
                repository: SkillRepository(location: "example-org/plugin-market"),
                installedAt: .now.addingTimeInterval(-86_400 * 20),
                updatedAt: .now.addingTimeInterval(-86_400 * 20),
                agents: [.preview("Claude Code", key: "claude-code", folder: nil)],
                pluginIdentifier: "charts@example-market",
                version: "1.2.0",
                gitWorkTreeURL: nil,
                isUpdateTracked: false,
                sourceFolderPath: nil,
                installedTreeHash: nil,
                pinnedRevision: nil
            ),
            Skill(
                folderName: "sql-tuner",
                displayName: "sql-tuner",
                summary: "Explains slow queries and suggests indexes.",
                folderURL: sharedFolder.appending(path: "sql-tuner"),
                resolvedFolderURL: sharedFolder.appending(path: "sql-tuner"),
                sourceKind: .skillsCLI,
                repository: SkillRepository(location: "example-org/agent-skills"),
                installedAt: .now.addingTimeInterval(-86_400 * 60),
                updatedAt: .now.addingTimeInterval(-86_400 * 60),
                agents: [.preview("Codex", key: "codex", folder: sharedFolder.appending(path: "sql-tuner"))],
                pluginIdentifier: nil,
                version: "0c1d2e3",
                gitWorkTreeURL: nil,
                isUpdateTracked: true,
                sourceFolderPath: "skills/sql-tuner",
                installedTreeHash: nil,
                pinnedRevision: "0c1d2e3f4a5b"
            ),
        ]
    }()
}

extension SkillHistory {
    /// A main line with one merged pull request; an older version is installed.
    static let preview: SkillHistory = {
        let day: TimeInterval = 86_400
        let now = Date()
        func revision(_ hash: String, _ parents: [String], _ title: String, _ author: String, daysAgo: Double, decorations: [String] = []) -> SkillRevision {
            SkillRevision(commitHash: hash, parentHashes: parents, title: title, authorName: author, date: now - daysAgo * day, decorations: decorations, folderTreeHash: "tree-\(hash)")
        }
        let revisions = [
            revision("b48c832aa1", ["8b067c5aa1", "9b03693aa1"], "Make the After examples read better", "Ada Brooks", daysAgo: 1, decorations: ["origin/main"]),
            revision("9b03693aa1", ["8b067c5aa1"], "Tighten the example section", "Lee Park", daysAgo: 2),
            revision("8b067c5aa1", ["e97c2c4aa1"], "Release 4.0.0", "Ada Brooks", daysAgo: 3, decorations: ["tag: v4.0.0"]),
            revision("e97c2c4aa1", ["1a98325aa1"], "Allow added specifics", "Sam Ortiz", daysAgo: 9),
            revision("1a98325aa1", ["8b3a178aa1"], "Rewrite unclear sentences", "Lee Park", daysAgo: 15),
            revision("8b3a178aa1", [], "First release", "Ada Brooks", daysAgo: 40, decorations: ["main"]),
        ]
        return SkillHistory(revisions: revisions, installedCommitHash: "8b3a178aa1", latestCommitHash: "b48c832aa1", isTruncated: false)
    }()
}

extension AvailableSkill {
    static let previewSamples: [AvailableSkill] = [
        AvailableSkill(relativePath: "skills/release-notes", name: "release-notes", summary: "Drafts release notes from merged pull requests."),
        AvailableSkill(relativePath: "skills/sql-tuner", name: "sql-tuner", summary: "Explains slow queries and suggests indexes."),
        AvailableSkill(relativePath: "skills/changelog-lint", name: "changelog-lint", summary: "Checks a CHANGELOG against Keep a Changelog."),
    ]
}

extension SkillLibrary {
    static let preview: SkillLibrary = {
        let samples = Skill.previewSamples
        return SkillLibrary(previewSkills: samples, statuses: [
            samples[0].id: .updateAvailable,
            samples[1].id: .locallyModified,
            samples[4].id: .pinned,
        ])
    }()
}
#endif
