//
//  SkillSourceBrowser.swift
//  SkillsBuddy
//
//  Lists the skills in a source before installing, so you can pick which ones
//  to add. Shallow-clones git sources into a temporary folder and reads each
//  SKILL.md; the install itself still goes through the `skills` CLI.
//

import Foundation

/// What someone typed into the Install sheet, resolved to something git can clone.
nonisolated enum SkillSourceInput: Equatable, Sendable {
    /// A clone URL, optionally pinned to a branch and narrowed to a subfolder.
    case git(cloneURL: String, branch: String?, subpath: String?)
    case localFolder(URL)

    /// Accepts `owner/repo`, `https://github.com/owner/repo[/tree/<branch>/<path>]`,
    /// any other git URL, or a local folder path.
    static func parse(_ rawInput: String) -> SkillSourceInput? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if input.hasPrefix("/") || input.hasPrefix("~") || input.hasPrefix("./") {
            return .localFolder(URL(fileURLWithPath: (input as NSString).expandingTildeInPath, isDirectory: true))
        }

        if let match = input.wholeMatch(of: /https?:\/\/github\.com\/([^\/\s]+)\/([^\/\s]+?)(?:\.git)?\/tree\/([^\/\s]+)(?:\/(.+?))?\/?/) {
            let (_, owner, repository, branch, subpath) = match.output
            return .git(
                cloneURL: "https://github.com/\(owner)/\(repository).git",
                branch: String(branch),
                subpath: subpath.map(String.init)
            )
        }

        if input.contains("://") || input.hasPrefix("git@") {
            return .git(cloneURL: input, branch: nil, subpath: nil)
        }

        if input.wholeMatch(of: /[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/) != nil {
            return .git(cloneURL: "https://github.com/\(input).git", branch: nil, subpath: nil)
        }
        return nil
    }
}

/// A skill found in a source, before it's installed.
nonisolated struct AvailableSkill: Identifiable, Hashable, Sendable {
    /// Path of the skill folder relative to the source root ("" for a root SKILL.md).
    let relativePath: String
    let name: String
    let summary: String

    var id: String { relativePath + "/" + name }
}

nonisolated struct SkillSourceBrowser: Sendable {
    let git: GitClient

    /// Folders the CLI never descends into (its `SKIP_DIRS`).
    private static let skippedFolderNames: Set<String> = ["node_modules", ".git", "dist", "build", "__pycache__"]
    /// Where the CLI looks first, and how deep. A subset of its priority list:
    /// the agent folders that matter for Claude Code.
    private static let priorityFolders: [(relativePath: String, maximumDepth: Int)] = [
        ("", 1),
        ("skills", 3),
        ("skills/.curated", 3),
        ("skills/.experimental", 3),
        ("skills/.system", 3),
        (".agents/skills", 3),
        (".claude/skills", 3),
    ]
    /// The CLI's fallback walk when the priority folders hold nothing.
    private static let fallbackDepth = 5

    @concurrent func availableSkills(in input: SkillSourceInput) async throws -> [AvailableSkill] {
        warnIfOnMainThread("SkillSourceBrowser.availableSkills")
        switch input {
        case .localFolder(let folderURL):
            return Self.findSkills(in: folderURL)

        case .git(let cloneURL, let branch, let subpath):
            let checkoutURL = FileManager.default.temporaryDirectory
                .appending(path: "SkillsBuddy-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: checkoutURL) }
            try await git.shallowClone(cloneURL, branch: branch, into: checkoutURL)
            let searchRoot = subpath.map { checkoutURL.appending(path: $0, directoryHint: .isDirectory) } ?? checkoutURL
            return Self.findSkills(in: searchRoot)
        }
    }

    /// Mirrors the CLI's discovery (`discoverSkills`): a root SKILL.md means the
    /// source *is* one skill; otherwise the priority folders, then a deep walk
    /// only if those found nothing. Names are deduplicated, first one wins, since
    /// `--skill <name>` can only pick one of them.
    static func findSkills(in rootURL: URL) -> [AvailableSkill] {
        let rootSkillFile = rootURL.appendingPathComponent("SKILL.md")
        if FileManager.default.fileExists(atPath: rootSkillFile.path) {
            return [availableSkill(at: rootURL, relativePath: "")]
        }

        var skills: [AvailableSkill] = []
        var seenNames = Set<String>()
        for folder in priorityFolders {
            let folderURL = folder.relativePath.isEmpty ? rootURL : rootURL.appending(path: folder.relativePath, directoryHint: .isDirectory)
            walk(folderURL, relativePath: folder.relativePath, depth: 1, maximumDepth: folder.maximumDepth, into: &skills, seenNames: &seenNames)
        }
        if skills.isEmpty {
            walk(rootURL, relativePath: "", depth: 1, maximumDepth: fallbackDepth, into: &skills, seenNames: &seenNames)
        }
        return skills
    }

    /// A folder with a SKILL.md is a skill and isn't searched further.
    private static func walk(
        _ folderURL: URL,
        relativePath: String,
        depth: Int,
        maximumDepth: Int,
        into skills: inout [AvailableSkill],
        seenNames: inout Set<String>
    ) {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        for childURL in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDirectory = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            let childPath = relativePath.isEmpty ? childURL.lastPathComponent : relativePath + "/" + childURL.lastPathComponent
            if FileManager.default.fileExists(atPath: childURL.appendingPathComponent("SKILL.md").path) {
                let skill = availableSkill(at: childURL, relativePath: childPath)
                if seenNames.insert(skill.name).inserted { skills.append(skill) }
            } else if depth < maximumDepth, !skippedFolderNames.contains(childURL.lastPathComponent) {
                walk(childURL, relativePath: childPath, depth: depth + 1, maximumDepth: maximumDepth, into: &skills, seenNames: &seenNames)
            }
        }
    }

    private static func availableSkill(at folderURL: URL, relativePath: String) -> AvailableSkill {
        let frontmatter = SkillFrontmatter.load(from: folderURL.appendingPathComponent("SKILL.md"))
        return AvailableSkill(
            relativePath: relativePath,
            name: frontmatter.name ?? folderURL.lastPathComponent,
            summary: frontmatter.description ?? ""
        )
    }
}
