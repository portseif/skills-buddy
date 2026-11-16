//
//  SkillScanner.swift
//  SkillsBuddy
//
//  Finds installed skills for every coding agent:
//
//  - `skills list -g --json` reports each global skill once, with the agents
//    that load it (the CLI knows ~80 agents' folders and which are installed).
//    Without the CLI, it falls back to Claude Code's `~/.claude/skills`.
//  - The CLI only looks one level down, but Hermes loads skills from category
//    folders too (`~/.hermes/skills/creative/<name>`); those come from a walk
//    of its folder that follows Hermes's own rules.
//  - `~/.agents/.skill-lock.json` says which came from the CLI, and from where.
//  - A skill folder inside a git clone is a git skill.
//  - `<plugin installPath>/skills/<name>/SKILL.md` for each Claude Code plugin
//    in `~/.claude/plugins/installed_plugins.json`.
//

import Foundation

nonisolated struct SkillScanResult: Sendable {
    var skills: [Skill]
    var warnings: [String]
    /// The `--agent` keys the CLI last installed to, for the Install sheet's defaults.
    var lastSelectedAgentKeys: [String]
}

nonisolated struct SkillScanner: Sendable {
    let homeDirectoryURL: URL
    let git: GitClient
    let cli: SkillsCLI
    var disabledStore: DisabledSkillStore = .standard

    static let claudeCodeAgentName = "Claude Code"

    var claudeSkillsURL: URL { homeDirectoryURL.appending(path: ".claude/skills", directoryHint: .isDirectory) }
    var lockFileURL: URL { homeDirectoryURL.appending(path: ".agents/.skill-lock.json") }
    var installedPluginsURL: URL { homeDirectoryURL.appending(path: ".claude/plugins/installed_plugins.json") }
    var knownMarketplacesURL: URL { homeDirectoryURL.appending(path: ".claude/plugins/known_marketplaces.json") }
    var claudeSettingsURL: URL { homeDirectoryURL.appending(path: ".claude/settings.json") }

    @concurrent func scan() async -> SkillScanResult {
        warnIfOnMainThread("SkillScanner.scan")
        // The lock file, the CLI's list and the plugins don't depend on each
        // other: read all three at once.
        async let lockFileRead = readLockFile()
        async let listing = listSkills()
        async let pluginsRead = readPluginSkills()
        let (lockFile, lockWarning) = await lockFileRead
        let (listedSkills, listWarning) = await listing
        let lockEntries = lockFile?.skills ?? [:]

        // Each skill reads its SKILL.md and, for a clone, asks git twice; build
        // them side by side.
        let listedFolders = listedSkills.compactMap { listed in listed.path.map { (listed, URL(fileURLWithPath: $0, isDirectory: true)) } }
        var skills = await concurrentMap(listedFolders) { listed, folderURL in
            await makeSkill(listedSkill: listed, folderURL: folderURL, lockEntries: lockEntries)
        }.compactMap { $0 }
        await appendHermesSkills(to: &skills, lockEntries: lockEntries)
        let fullyDisabledSkills = await attachDisabledEntries(to: &skills, lockEntries: lockEntries)
        skills += fullyDisabledSkills

        let (pluginSkills, pluginWarning) = await pluginsRead
        skills += pluginSkills

        skills.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let warnings = [lockWarning, listWarning, pluginWarning].compactMap { $0 }
        return SkillScanResult(skills: skills, warnings: warnings, lastSelectedAgentKeys: lockFile?.lastSelectedAgents ?? [])
    }

    @concurrent private func readLockFile() async -> (SkillLockFile?, warning: String?) {
        guard FileManager.default.fileExists(atPath: lockFileURL.path) else { return (nil, nil) }
        do {
            return (try SkillLockFile.load(from: lockFileURL), nil)
        } catch {
            return (nil, "Couldn't read \(lockFileURL.path): \(error.localizedDescription)")
        }
    }

    /// Every agent's skills from the CLI, or Claude Code's folder when it can't run.
    @concurrent private func listSkills() async -> ([ListedSkill], warning: String?) {
        do {
            return (try await cli.listInstalledSkills(), nil)
        } catch {
            let fallback = skillFolders(in: claudeSkillsURL).map { folderURL in
                ListedSkill(name: folderURL.lastPathComponent, path: folderURL.path, agents: [Self.claudeCodeAgentName], status: nil)
            }
            return (fallback, "Couldn't list skills for every agent (\(error.localizedDescription)). Showing Claude Code's skills only.")
        }
    }

    @concurrent private func readPluginSkills() async -> ([Skill], warning: String?) {
        do {
            return (try pluginSkills(), nil)
        } catch {
            return ([], "Couldn't read installed plugins: \(error.localizedDescription)")
        }
    }

    /// Hermes's `EXCLUDED_SKILL_DIRS`: its own state, version control and dependencies.
    private static let hermesSkippedFolderNames: Set<String> = [
        ".git", ".github", ".hub", ".archive", ".curator_backups", ".locks", ".hermes-dist",
        ".venv", "venv", "node_modules", "site-packages", "__pycache__",
        ".tox", ".nox", ".pytest_cache", ".mypy_cache", ".ruff_cache",
    ]
    /// Hermes's `SKILL_SUPPORT_DIRS`: a skill's own files, never searched for skills.
    private static let skillSupportFolderNames: Set<String> = ["references", "templates", "assets", "scripts"]

    private func hermesSkillFolders() -> [URL] {
        Self.hermesSkillFolders(in: homeDirectoryURL.appending(path: ".hermes/skills"))
    }

    /// Every skill folder under `rootURL`, found the way Hermes walks its skills
    /// folder: any folder with a SKILL.md at any depth, inside another skill
    /// too, following symlinks, minus Hermes's skipped folders and a skill's
    /// support folders.
    static func hermesSkillFolders(in rootURL: URL) -> [URL] {
        let fileManager = FileManager.default
        var visitedPaths = Set<String>()

        func walk(_ folderURL: URL, depth: Int) -> [URL] {
            let resolvedPath = folderURL.resolvingSymlinksInPath().path
            // A symlink back up the tree would loop forever.
            guard visitedPaths.insert(resolvedPath).inserted else { return [] }
            let isSkill = depth > 0 && fileManager.fileExists(atPath: folderURL.appendingPathComponent("SKILL.md").path)

            // Listed by name from the resolved path, since listing a URL doesn't
            // follow a symlinked folder, and joined to the path as found.
            let childNames = (try? fileManager.contentsOfDirectory(atPath: resolvedPath)) ?? []
            let nestedFolders = childNames.sorted().flatMap { childName -> [URL] in
                guard !hermesSkippedFolderNames.contains(childName),
                      !(isSkill && skillSupportFolderNames.contains(childName)) else { return [] }
                let childURL = folderURL.appending(path: childName, directoryHint: .isDirectory)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: childURL.path, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }
                return walk(childURL, depth: depth + 1)
            }
            return (isSkill ? [folderURL] : []) + nestedFolders
        }

        return walk(rootURL, depth: 0)
    }

    private func appendHermesSkills(to skills: inout [Skill], lockEntries: [String: SkillLockEntry]) async {
        guard let agent = AgentRegistry.definition(key: "hermes-agent") else { return }
        let root = homeDirectoryURL.appending(path: ".hermes/skills").standardizedFileURL.path + "/"
        for folder in hermesSkillFolders() {
            let install = SkillAgentInstall(displayName: agent.displayName, key: agent.key, folderURL: folder)
            let resolvedPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
            let relativePath = String(folder.standardizedFileURL.path.dropFirst(root.count))
            if !relativePath.contains("/"), let index = skills.firstIndex(where: {
                $0.folderName == relativePath || $0.resolvedFolderURL.standardizedFileURL.path == resolvedPath
            }) {
                skills[index].agents.removeAll { $0.displayName == agent.displayName }
                skills[index].agents.append(install)
                skills[index].agents.sort { $0.displayName < $1.displayName }
                continue
            }
            let listed = ListedSkill(name: relativePath, path: folder.path, agents: [agent.displayName], status: nil)
            if let skill = await makeSkill(listedSkill: listed, folderURL: folder, lockEntries: lockEntries, folderName: relativePath) {
                skills.append(skill)
            }
        }
    }

    // MARK: - Disabled skills

    /// Attaches Disable's stored entries to the skills still loaded somewhere,
    /// and returns the skills disabled for every agent (no agent lists them),
    /// built from their stored copy.
    @concurrent private func attachDisabledEntries(to skills: inout [Skill], lockEntries: [String: SkillLockEntry]) async -> [Skill] {
        let entriesByName = Dictionary(grouping: disabledStore.entries(), by: \.skillName)
        for index in skills.indices {
            if let entries = entriesByName[skills[index].folderName] { skills[index].disabledEntries = entries }
        }

        let loadedNames = Set(skills.map(\.folderName))
        let store = disabledStore
        // A stored link may point at a folder that's stored too; any entry with real files will do.
        let storedSkills = entriesByName.compactMap { skillName, entries -> (name: String, entries: [DisabledSkillEntry], folderURL: URL)? in
            guard !loadedNames.contains(skillName),
                  let folderURL = entries.lazy.compactMap(store.skillFolder(of:)).first else { return nil }
            return (skillName, entries, folderURL)
        }
        return await concurrentMap(storedSkills) { stored -> Skill? in
            let listed = ListedSkill(name: stored.name, path: stored.folderURL.path, agents: [], status: nil)
            guard var skill = await makeSkill(listedSkill: listed, folderURL: stored.folderURL, lockEntries: lockEntries, folderName: stored.name) else { return nil }
            skill.disabledEntries = stored.entries
            return skill
        }.compactMap { $0 }
    }

    // MARK: - Agent skills

    @concurrent private func makeSkill(listedSkill: ListedSkill, folderURL: URL, lockEntries: [String: SkillLockEntry], folderName: String? = nil) async -> Skill? {
        let resolvedURL = folderURL.resolvingSymlinksInPath()
        let skillFileURL = resolvedURL.appendingPathComponent("SKILL.md")
        guard FileManager.default.fileExists(atPath: skillFileURL.path) else { return nil }

        let folderName = folderName ?? folderURL.lastPathComponent
        let frontmatter = SkillFrontmatter.load(from: skillFileURL)
        let agents = listedSkill.agents.sorted().map { agentName in
            let definition = AgentRegistry.definition(displayName: agentName)
            let agentFolderURL = definition?.skillFolderURL(named: folderName, homeDirectoryURL: homeDirectoryURL)
            return SkillAgentInstall(
                displayName: agentName,
                key: definition?.key,
                folderURL: agentFolderURL.flatMap { Self.itemExists(at: $0) ? $0 : nil }
            )
        }

        if let lockEntry = lockEntries[listedSkill.name] ?? lockEntries[folderName] {
            let isGitHub = lockEntry.sourceType == "github"
            return Skill(
                folderName: folderName,
                displayName: frontmatter.name ?? folderName,
                summary: frontmatter.description ?? "",
                folderURL: folderURL,
                resolvedFolderURL: resolvedURL,
                sourceKind: .skillsCLI,
                repository: SkillRepository(location: isGitHub ? lockEntry.source : (lockEntry.sourceUrl ?? lockEntry.source)),
                installedAt: lockEntry.installedAt,
                updatedAt: lockEntry.updatedAt,
                agents: agents,
                pluginIdentifier: nil,
                version: lockEntry.ref.map { String($0.prefix(7)) } ?? lockEntry.skillFolderHash.flatMap { $0.isEmpty ? nil : String($0.prefix(7)) },
                gitWorkTreeURL: nil,
                isUpdateTracked: lockEntry.supportsUpdateCheck,
                sourceFolderPath: lockEntry.skillFolderPath,
                installedTreeHash: lockEntry.skillFolderHash.flatMap { $0.isEmpty ? nil : $0 },
                pinnedRevision: lockEntry.ref
            )
        }

        // A git clone in the listed folder or in any agent's copy of it.
        let candidateFolders = [resolvedURL] + agents.compactMap { $0.folderURL?.resolvingSymlinksInPath() }
        for candidateURL in candidateFolders {
            guard let workTreeURL = GitClient.workTreeRoot(containing: candidateURL, homeDirectoryURL: homeDirectoryURL) else { continue }
            async let remote = git.remoteURL(workTree: workTreeURL)
            async let head = git.shortHead(workTree: workTreeURL)
            let (remoteURL, shortHead) = await (remote, head)
            let workTreePath = workTreeURL.standardizedFileURL.path
            let candidatePath = candidateURL.standardizedFileURL.path
            let relativeFolder = candidatePath == workTreePath ? "" : String(candidatePath.dropFirst(workTreePath.count + 1))
            return Skill(
                folderName: folderName,
                displayName: frontmatter.name ?? folderName,
                summary: frontmatter.description ?? "",
                folderURL: folderURL,
                resolvedFolderURL: candidateURL,
                sourceKind: .git,
                repository: remoteURL.map(SkillRepository.init(location:)),
                installedAt: creationDate(of: folderURL),
                updatedAt: modificationDate(of: candidateURL.appendingPathComponent("SKILL.md")),
                agents: agents,
                pluginIdentifier: nil,
                version: shortHead,
                gitWorkTreeURL: workTreeURL,
                isUpdateTracked: remoteURL != nil,
                sourceFolderPath: relativeFolder,
                installedTreeHash: nil,
                pinnedRevision: nil
            )
        }

        return Skill(
            folderName: folderName,
            displayName: frontmatter.name ?? folderName,
            summary: frontmatter.description ?? "",
            folderURL: folderURL,
            resolvedFolderURL: resolvedURL,
            sourceKind: .local,
            repository: nil,
            installedAt: creationDate(of: folderURL),
            updatedAt: modificationDate(of: skillFileURL),
            agents: agents,
            pluginIdentifier: nil,
            version: nil,
            gitWorkTreeURL: nil,
            isUpdateTracked: false,
            sourceFolderPath: nil,
            installedTreeHash: nil,
            pinnedRevision: nil
        )
    }

    // MARK: - Plugins

    private nonisolated struct InstalledPlugins: Decodable {
        let plugins: [String: [Installation]]

        nonisolated struct Installation: Decodable {
            let scope: String
            let installPath: String
            let version: String?
        }
    }

    private nonisolated struct KnownMarketplace: Decodable {
        let source: Source

        nonisolated struct Source: Decodable {
            let repo: String?
            let url: String?
        }
    }

    private nonisolated struct ClaudeSettings: Decodable {
        let enabledPlugins: [String: Bool]?
    }

    private func pluginSkills() throws -> [Skill] {
        guard FileManager.default.fileExists(atPath: installedPluginsURL.path) else { return [] }
        let installed = try JSONDecoder().decode(InstalledPlugins.self, from: Data(contentsOf: installedPluginsURL))
        let marketplaces = (try? JSONDecoder().decode([String: KnownMarketplace].self, from: Data(contentsOf: knownMarketplacesURL))) ?? [:]
        let enabledPlugins = (try? JSONDecoder().decode(ClaudeSettings.self, from: Data(contentsOf: claudeSettingsURL)))?.enabledPlugins ?? [:]
        let claudeCode = AgentRegistry.definition(displayName: Self.claudeCodeAgentName)

        var skills: [Skill] = []
        for (pluginIdentifier, installations) in installed.plugins {
            // A plugin can be installed per project and for the user; the user install is the one that applies everywhere.
            guard let installation = installations.first(where: { $0.scope == "user" }) ?? installations.first else { continue }
            let marketplaceName = pluginIdentifier.split(separator: "@").last.map(String.init) ?? ""
            let marketplaceSource = marketplaces[marketplaceName]?.source
            let repository = (marketplaceSource?.repo ?? marketplaceSource?.url).map(SkillRepository.init(location:))
            let installURL = URL(fileURLWithPath: installation.installPath, isDirectory: true)
            // Only an explicit `false` disables; a project's settings can enable it too.
            let isEnabled = enabledPlugins[pluginIdentifier] != false

            for folderURL in skillFolders(in: installURL.appending(path: "skills", directoryHint: .isDirectory)) {
                let resolvedURL = folderURL.resolvingSymlinksInPath()
                let frontmatter = SkillFrontmatter.load(from: resolvedURL.appendingPathComponent("SKILL.md"))
                skills.append(Skill(
                    folderName: folderURL.lastPathComponent,
                    displayName: frontmatter.name ?? folderURL.lastPathComponent,
                    summary: frontmatter.description ?? "",
                    folderURL: folderURL,
                    resolvedFolderURL: resolvedURL,
                    sourceKind: .plugin,
                    repository: repository,
                    installedAt: creationDate(of: installURL),
                    updatedAt: modificationDate(of: installURL),
                    agents: isEnabled ? [SkillAgentInstall(displayName: Self.claudeCodeAgentName, key: claudeCode?.key, folderURL: nil)] : [],
                    pluginIdentifier: pluginIdentifier,
                    version: installation.version,
                    gitWorkTreeURL: nil,
                    isUpdateTracked: false,
                    sourceFolderPath: nil,
                    installedTreeHash: nil,
                    pinnedRevision: nil
                ))
            }
        }
        return skills
    }

    // MARK: - Files

    /// Visible children of `directoryURL` (following symlinks) that hold a SKILL.md.
    private func skillFolders(in directoryURL: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.filter { childURL in
            FileManager.default.fileExists(atPath: childURL.resolvingSymlinksInPath().appendingPathComponent("SKILL.md").path)
        }
    }

    /// True for a broken symlink too, unlike `fileExists`, so it can still be removed.
    private static func itemExists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func creationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
