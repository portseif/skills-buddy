//
//  ParsingTests.swift
//  SkillsBuddyTests
//

import Foundation
import Testing
@testable import Skills_Buddy

struct SkillFrontmatterTests {
    @Test func readsPlainAndQuotedScalars() {
        let markdown = """
        ---
        name: release-notes
        description: "Drafts release notes: grouped by area"
        license: MIT
        ---
        # Body
        """
        let frontmatter = SkillFrontmatter.parse(markdown)
        #expect(frontmatter.name == "release-notes")
        #expect(frontmatter.description == "Drafts release notes: grouped by area")
    }

    @Test func foldsBlockScalars() {
        let markdown = """
        ---
        name: sql-tuner
        description: >
          Explains slow queries
          and suggests indexes.
        metadata:
          version: 2
        ---
        """
        let frontmatter = SkillFrontmatter.parse(markdown)
        #expect(frontmatter.description == "Explains slow queries and suggests indexes.")
    }

    @Test func ignoresFilesWithoutFrontmatter() {
        #expect(SkillFrontmatter.parse("# Just a heading\nname: nope") == SkillFrontmatter())
    }
}

struct SkillsCLIOutputTests {
    @Test func parsesOutdatedSkillsFromCheckOutput() {
        let output = "\u{1B}[38;5;250mChecking for skill updates…\u{1B}[0m\n\n\r\u{1B}[2mChecking skills from source: a/b\u{1B}[0m\u{1B}[K\n\u{1B}[38;5;250m↑ find-skills has an update\u{1B}[0m\n↑ huashu-design has an update\n2 skill(s) can be updated"
        #expect(SkillsCLI.parseCheckOutput(output) == ["find-skills", "huashu-design"])
    }

    @Test func upToDateOutputHasNoUpdates() {
        #expect(SkillsCLI.parseCheckOutput("✓ All global skills are up to date").isEmpty)
    }
}

struct SkillSourceInputTests {
    @Test func expandsGitHubShorthand() {
        #expect(SkillSourceInput.parse("vercel-labs/skills") == .git(cloneURL: "https://github.com/vercel-labs/skills.git", branch: nil, subpath: nil))
    }

    @Test func splitsGitHubTreeURLs() {
        #expect(SkillSourceInput.parse("https://github.com/owner/repo/tree/main/skills/foo") == .git(cloneURL: "https://github.com/owner/repo.git", branch: "main", subpath: "skills/foo"))
        #expect(SkillSourceInput.parse("https://github.com/owner/repo/tree/dev") == .git(cloneURL: "https://github.com/owner/repo.git", branch: "dev", subpath: nil))
    }

    @Test func passesOtherGitURLsThrough() {
        #expect(SkillSourceInput.parse("git@github.com:owner/repo.git") == .git(cloneURL: "git@github.com:owner/repo.git", branch: nil, subpath: nil))
        #expect(SkillSourceInput.parse("https://gitlab.com/group/repo") == .git(cloneURL: "https://gitlab.com/group/repo", branch: nil, subpath: nil))
    }

    @Test func rejectsNonsense() {
        #expect(SkillSourceInput.parse("   ") == nil)
        #expect(SkillSourceInput.parse("just words here") == nil)
    }
}

struct SkillSourceBrowserTests {
    private func makeSkill(at relativePath: String, name: String, in rootURL: URL) throws {
        let folderURL = rootURL.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try "---\nname: \(name)\n---\n".write(to: folderURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "SkillsBuddyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func prefersPriorityFoldersOverHiddenCopies() throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try makeSkill(at: "skills/find-skills", name: "find-skills", in: rootURL)
        try makeSkill(at: ".automations/triage/skills/triage", name: "triage", in: rootURL)

        #expect(SkillSourceBrowser.findSkills(in: rootURL).map(\.name) == ["find-skills"])
    }

    @Test func fallsBackToADeepWalkAndDeduplicatesNames() throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try makeSkill(at: "packages/a/triage", name: "triage", in: rootURL)
        try makeSkill(at: "packages/b/triage", name: "triage", in: rootURL)
        try makeSkill(at: "node_modules/x/ignored", name: "ignored", in: rootURL)

        let skills = SkillSourceBrowser.findSkills(in: rootURL)
        #expect(skills.map(\.name) == ["triage"])
        #expect(skills.first?.relativePath == "packages/a/triage")
    }

    @Test func rootSkillIsTheOnlySkill() throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try makeSkill(at: "", name: "solo", in: rootURL)
        try makeSkill(at: "skills/other", name: "other", in: rootURL)

        #expect(SkillSourceBrowser.findSkills(in: rootURL).map(\.name) == ["solo"])
    }
}

struct SkillLockFileTests {
    @Test func decodesEntriesAndDates() throws {
        let json = """
        {"version": 3, "skills": {"find-skills": {
          "source": "vercel-labs/skills", "sourceType": "github",
          "sourceUrl": "https://github.com/vercel-labs/skills.git",
          "skillPath": "skills/find-skills/SKILL.md",
          "skillFolderHash": "76a98a285cb0434f3d39e1a873823556330e398b",
          "installedAt": "2026-04-27T15:22:09.987Z", "updatedAt": "2026-11-12T04:38:08.279Z"
        }, "untracked": {"source": "./local", "sourceType": "local", "skillFolderHash": ""}}}
        """
        let lockFile = try JSONDecoder.makeSkillLockDecoder().decode(SkillLockFile.self, from: Data(json.utf8))
        let entry = try #require(lockFile.skills["find-skills"])
        #expect(entry.supportsUpdateCheck)
        #expect(entry.installedAt != nil)
        #expect(entry.skillFolderPath == "skills/find-skills")
        #expect(entry.ref == nil)
        #expect(lockFile.skills["untracked"]?.supportsUpdateCheck == false)
    }

    @Test func readsPinsAndLastSelectedAgents() throws {
        let json = """
        {"version": 3, "lastSelectedAgents": ["claude-code", "codex"], "skills": {"root-skill": {
          "source": "owner/repo", "sourceType": "github", "ref": "0123abc", "skillPath": "SKILL.md", "skillFolderHash": "abc"
        }}}
        """
        let lockFile = try JSONDecoder.makeSkillLockDecoder().decode(SkillLockFile.self, from: Data(json.utf8))
        #expect(lockFile.lastSelectedAgents == ["claude-code", "codex"])
        #expect(lockFile.skills["root-skill"]?.ref == "0123abc")
        #expect(lockFile.skills["root-skill"]?.skillFolderPath == "")
    }
}

struct SkillRepositoryTests {
    @Test func displaysOwnerAndRepo() {
        #expect(SkillRepository(location: "https://github.com/blader/humanizer.git").displayName == "blader/humanizer")
        #expect(SkillRepository(location: "git@github.com:owner/repo.git").webURL?.absoluteString == "https://github.com/owner/repo")
        #expect(SkillRepository(location: "owner/repo").webURL?.absoluteString == "https://github.com/owner/repo")
    }

    @Test func expandsShorthandForCloning() {
        #expect(SkillRepository(location: "vercel-labs/skills").cloneURL == "https://github.com/vercel-labs/skills.git")
        #expect(SkillRepository(location: "git@github.com:owner/repo.git").cloneURL == "git@github.com:owner/repo.git")
        #expect(SkillHistoryReader.cacheFolderName(for: SkillRepository(location: "vercel-labs/skills")) == "vercel-labs--skills")
    }
}

struct SkillsCLIListTests {
    @Test func decodesListJSONAfterNpmNotices() throws {
        let output = """
        npm notice run npx
        [
          {"name": "bb-cli", "path": "/Users/example/.agents/skills/bb-cli", "scope": "global", "agents": ["Claude Code", "Codex"], "source": null, "status": "untracked"},
          {"name": "caveman", "path": null, "scope": "global", "agents": [], "status": "missing"}
        ]
        """
        let skills = try SkillsCLI.parseListOutput(output)
        #expect(skills.map(\.name) == ["bb-cli", "caveman"])
        #expect(skills[0].agents == ["Claude Code", "Codex"])
        #expect(skills[1].path == nil)
    }
}

struct SkillHistoryParsingTests {
    @Test func parsesLogRecordsAndPullRequestTitles() {
        let separator = "\u{1F}"
        let record = "\u{1E}"
        let output = [
            ["b48c832", "8b067c5 9b03693", "Ada Brooks", "2026-11-01T10:00:00+00:00", "HEAD -> main, origin/main, origin/HEAD", "Merge pull request #333 from org/release", "Release 4.0.0\n\nDetails"].joined(separator: separator),
            ["8b067c5", "", "Lee Park", "2026-10-30T10:00:00+00:00", "tag: v4.0.0", "Initial commit", ""].joined(separator: separator),
        ].map { $0 + record }.joined(separator: "\n")

        let revisions = SkillHistory.parseLog(output)
        #expect(revisions.count == 2)
        #expect(revisions[0].parentHashes == ["8b067c5", "9b03693"])
        #expect(revisions[0].title == "Release 4.0.0")
        #expect(revisions[0].decorations == ["main", "origin/main"])
        #expect(revisions[1].parentHashes.isEmpty)
        #expect(revisions[1].title == "Initial commit")
        #expect(revisions[1].decorations == ["tag: v4.0.0"])
    }
}

struct AgentRegistryTests {
    @Test func bundledRegistryMapsNamesToKeysAndFolders() throws {
        let claudeCode = try #require(AgentRegistry.definition(displayName: "Claude Code"))
        #expect(claudeCode.key == "claude-code")
        let home = URL(fileURLWithPath: "/Users/example")
        #expect(claudeCode.skillFolderURL(named: "humanizer", homeDirectoryURL: home)?.path == "/Users/example/.claude/skills/humanizer")
        #expect(AgentRegistry.definition(key: "codex")?.globalSkillsPath == "~/.agents/skills/")
    }
}
