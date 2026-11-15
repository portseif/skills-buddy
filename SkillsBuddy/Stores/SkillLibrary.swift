//
//  SkillLibrary.swift
//  SkillsBuddy
//
//  The app's state: installed skills, their update status, and the actions
//  that change them. Long-running work happens in the services off the main
//  actor; this only records results.
//

import BlissUI
import Foundation
import Observation

/// One agent and how many skills it has, for the sidebar.
nonisolated struct AgentSkillCount: Hashable, Sendable {
    let agentName: String
    let count: Int
}

/// One repository and how many skills come from it, for the sidebar.
nonisolated struct RepositorySkillCount: Hashable, Sendable {
    let repository: SkillRepository
    let count: Int
}

@Observable
final class SkillLibrary {
    private(set) var skills: [Skill] = [] {
        didSet { updateSkillDerivedValues() }
    }
    private(set) var statuses: [Skill.ID: SkillUpdateStatus] = [:] {
        didSet { updateSkillsWithUpdates() }
    }
    // Derived from `skills` and `statuses`, stored so the views that show them
    // (title bar, sidebar) don't refilter every skill on each render.
    /// Skills whose last check found an update.
    private(set) var skillsWithUpdates: [Skill] = []
    /// Each agent with at least one skill, most skills first.
    private(set) var agentSkillCounts: [AgentSkillCount] = []
    /// How many skills come from each kind of source.
    private(set) var sourceCounts: [SkillSourceKind: Int] = [:]
    /// Repositories with agent skills, most skills first. Plugin marketplaces
    /// are left out: they'd crowd the list and update elsewhere.
    private(set) var repositoryCounts: [RepositorySkillCount] = []
    private(set) var disabledSkillCount = 0
    private(set) var scanWarnings: [String] = []
    private(set) var isScanning = false
    private(set) var isCheckingForUpdates = false
    private(set) var lastCheckedAt: Date?
    /// What's running right now ("Updating humanizer…"), or nil when idle.
    private(set) var activeOperation: String?
    /// Output from every git and CLI command this session, oldest first.
    private(set) var activityLog: [TerminalOutputLine] = [] {
        didSet { hasActivity = !activityLog.isEmpty }
    }
    /// Whether there's any log to show; changes far less often than the log,
    /// so a view that only needs this doesn't redraw for every line.
    private(set) var hasActivity = false
    /// Set when a check or action failed in a way the user should see.
    var errorMessage: String?
    /// The `--agent` keys the CLI last installed to.
    private(set) var lastSelectedAgentKeys: [String] = []
    /// When each skill was last used in Claude Code, keyed as it names them
    /// (`humanizer`, `figma:figma-use`). Empty until the first read finishes.
    private(set) var lastUseDates: [String: Date] = [:]
    private(set) var isReadingUsage = false

    private let homeDirectoryURL: URL
    /// The login shell's PATH, looked up once; callers that ask while it's
    /// still running share the same lookup.
    @ObservationIgnored private var environmentTask: Task<ShellEnvironment, Never>?

    init(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectoryURL = homeDirectoryURL
    }

    /// A library pre-filled for previews; never touches disk.
    init(previewSkills: [Skill], statuses: [Skill.ID: SkillUpdateStatus] = [:]) {
        self.homeDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        self.skills = previewSkills
        self.statuses = statuses
        self.lastCheckedAt = .now.addingTimeInterval(-600)
        // `didSet` doesn't run during init.
        updateSkillDerivedValues()
    }

    // MARK: - Derived

    func status(of skill: Skill) -> SkillUpdateStatus {
        // Checked first: a disabled skill isn't updated, whatever the source says.
        if skill.isFullyDisabled { return .disabled }
        if let status = statuses[skill.id] { return status }
        switch skill.sourceKind {
        case .plugin: return .managedByPlugin
        case .local: return .notTracked
        case .skillsCLI where skill.pinnedRevision != nil: return .pinned
        case .skillsCLI, .git: return skill.isUpdateTracked ? .unchecked : .notTracked
        }
    }

    private func updateSkillDerivedValues() {
        let counts = Dictionary(skills.flatMap { $0.agents.map(\.displayName) }.map { ($0, 1) }, uniquingKeysWith: +)
        agentSkillCounts = counts.map { AgentSkillCount(agentName: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.agentName < $1.agentName }
        sourceCounts = Dictionary(skills.map { ($0.sourceKind, 1) }, uniquingKeysWith: +)
        let repositoryGroups = Dictionary(grouping: skills.filter { $0.sourceKind != .plugin }.compactMap(\.repository)) { $0 }
        repositoryCounts = repositoryGroups
            .map { RepositorySkillCount(repository: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.repository.displayName < $1.repository.displayName }
        disabledSkillCount = skills.count(where: { !$0.disabledEntries.isEmpty })
        updateSkillsWithUpdates()
    }

    private func updateSkillsWithUpdates() {
        skillsWithUpdates = skills.filter { status(of: $0).canUpdate }
    }

    /// Agents worth offering in the Install sheet: those with skills, plus the
    /// ones the CLI last installed to.
    var installableAgents: [AgentDefinition] {
        let fromSkills = Set(skills.flatMap { $0.agents.map(\.displayName) }).compactMap(AgentRegistry.definition(displayName:))
        let fromLastInstall = lastSelectedAgentKeys.compactMap(AgentRegistry.definition(key:))
        return Array(Set(fromSkills + fromLastInstall)).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// The CLI's last pick, or every installable agent when there isn't one.
    var defaultInstallAgentKeys: Set<String> {
        let available = Set(installableAgents.map(\.key))
        let lastPick = Set(lastSelectedAgentKeys).intersection(available)
        return lastPick.isEmpty ? available : lastPick
    }

    /// Agents in the library that read the same skills folder as `agentName`
    /// (Codex, Pi, Warp and Zed all read ~/.agents/skills), so removing or
    /// disabling there reaches them too.
    func agentsSharingFolder(with agentName: String) -> [String] {
        guard let path = AgentRegistry.definition(displayName: agentName)?.globalSkillsPath else { return [] }
        let present = Set(skills.flatMap { $0.agents.map(\.displayName) + $0.disabledAgentNames })
        return AgentRegistry.all
            .filter { $0.globalSkillsPath == path && $0.displayName != agentName && present.contains($0.displayName) }
            .map(\.displayName)
            .sorted()
    }

    var isBusy: Bool { isScanning || isCheckingForUpdates || activeOperation != nil }

    /// When Claude Code last loaded the skill (a `Skill` tool call or its slash
    /// command), or nil if no session transcript shows it. A plugin's skills are
    /// named `plugin:skill` there.
    func lastUsedAt(_ skill: Skill) -> Date? {
        let names: [String]
        if let pluginIdentifier = skill.pluginIdentifier {
            let pluginName = pluginIdentifier.split(separator: "@").first.map(String.init) ?? pluginIdentifier
            names = ["\(pluginName):\(skill.folderName)", "\(pluginName):\(skill.displayName)"]
        } else {
            names = [skill.folderName, skill.displayName]
        }
        return names.compactMap { lastUseDates[$0] }.max()
    }

    func skill(withID id: Skill.ID?) -> Skill? {
        guard let id else { return nil }
        return skills.first { $0.id == id }
    }

    // MARK: - Scanning

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let environment = await resolvedEnvironment()
        let scanner = SkillScanner(
            homeDirectoryURL: homeDirectoryURL,
            git: GitClient(environment: environment),
            cli: SkillsCLI(environment: environment)
        )
        let result = await scanner.scan()
        skills = result.skills
        scanWarnings = result.warnings
        lastSelectedAgentKeys = result.lastSelectedAgentKeys
        // Keep statuses for skills that are still here; IDs are path-based.
        let currentIDs = Set(result.skills.map(\.id))
        statuses = statuses.filter { currentIDs.contains($0.key) }
        // Not awaited: the first read covers every transcript and can take a while.
        Task { await refreshUsage() }
    }

    /// Re-reads Claude Code's transcripts for when each skill was last used.
    func refreshUsage() async {
        guard !isReadingUsage else { return }
        isReadingUsage = true
        defer { isReadingUsage = false }
        lastUseDates = await SkillUsageReader(homeDirectoryURL: homeDirectoryURL).lastUseDates()
    }

    // MARK: - Checking for updates

    func checkForUpdates() async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        let environment = await resolvedEnvironment()
        let trackedSkills = skills.filter { $0.isUpdateTracked && !$0.isFullyDisabled && ($0.sourceKind == .skillsCLI || $0.sourceKind == .git) }
        statuses.merge(trackedSkills.map { ($0.id, .checking) }) { _, checking in checking }
        appendLog("Checking \(trackedSkills.count) skills for updates…", type: .system)

        async let cliStatuses = checkCLISkills(trackedSkills.filter { $0.sourceKind == .skillsCLI }, environment: environment)
        async let gitStatuses = checkGitSkills(trackedSkills.filter { $0.sourceKind == .git }, environment: environment)
        let results = await cliStatuses.merging(gitStatuses) { first, _ in first }
        statuses.merge(results) { _, new in new }
        lastCheckedAt = .now

        let updateCount = skillsWithUpdates.count
        appendLog(updateCount == 0 ? "Everything is up to date." : "\(updateCount) update(s) available.", type: .system)
    }

    private func checkCLISkills(_ cliSkills: [Skill], environment: ShellEnvironment) async -> [Skill.ID: SkillUpdateStatus] {
        guard !cliSkills.isEmpty else { return [:] }
        do {
            let namesWithUpdates = try await SkillsCLI(environment: environment).skillNamesWithUpdates()
            let lowercasedNames = Set(namesWithUpdates.map { $0.lowercased() })
            return Dictionary(uniqueKeysWithValues: cliSkills.map { skill in
                // A pinned skill is checked against its pin, so the CLI never reports one.
                if skill.pinnedRevision != nil { return (skill.id, .pinned) }
                return (skill.id, lowercasedNames.contains(skill.folderName.lowercased()) ? .updateAvailable : .upToDate)
            })
        } catch {
            let message = error.localizedDescription
            appendLog("skills check failed: \(message)", type: .stderr)
            return Dictionary(uniqueKeysWithValues: cliSkills.map { ($0.id, .failed(message)) })
        }
    }

    /// One fetch per clone, however many skills it holds.
    private func checkGitSkills(_ gitSkills: [Skill], environment: ShellEnvironment) async -> [Skill.ID: SkillUpdateStatus] {
        let git = GitClient(environment: environment)
        let skillsByWorkTree = Dictionary(grouping: gitSkills.filter { $0.gitWorkTreeURL != nil }) { $0.gitWorkTreeURL! }

        return await withTaskGroup(of: [Skill.ID: SkillUpdateStatus].self) { group in
            for (workTreeURL, skillsInTree) in skillsByWorkTree {
                group.addTask {
                    let status: SkillUpdateStatus
                    do {
                        let treeStatus = try await git.status(workTree: workTreeURL)
                        if treeStatus.hasLocalChanges {
                            status = .locallyModified
                        } else {
                            status = treeStatus.commitsBehind > 0 ? .updateAvailable : .upToDate
                        }
                    } catch GitError.noUpstream {
                        status = .noUpstream
                    } catch {
                        status = .failed(error.localizedDescription)
                    }
                    return Dictionary(uniqueKeysWithValues: skillsInTree.map { ($0.id, status) })
                }
            }
            var merged: [Skill.ID: SkillUpdateStatus] = [:]
            for await partial in group { merged.merge(partial) { _, new in new } }
            return merged
        }
    }

    // MARK: - Tracking a remote branch

    /// What Track Remote Branch would do for a git skill, or nil when its clone
    /// has no remote branch to follow.
    func trackingPlan(for skill: Skill) async -> GitTrackingPlan? {
        guard let workTreeURL = skill.gitWorkTreeURL else { return nil }
        return await GitClient(environment: await resolvedEnvironment()).trackingPlan(workTree: workTreeURL)
    }

    /// Points the skill's clone at `plan.remoteBranch`, then checks it again.
    func trackRemoteBranch(for skill: Skill, plan: GitTrackingPlan) async {
        guard let workTreeURL = skill.gitWorkTreeURL else { return }
        if plan.movesHead {
            let git = GitClient(environment: await resolvedEnvironment())
            if (try? await git.hasLocalChanges(workTree: workTreeURL)) ?? true {
                errorMessage = "\(skill.displayName)'s clone has uncommitted changes. Commit or discard them before switching it to \(plan.localBranch)."
                return
            }
        }
        let succeeded = await runOperation("Tracking \(plan.remoteBranch) for \(skill.displayName)") { environment, onOutput in
            try await GitClient(environment: environment).trackRemoteBranch(plan, workTree: workTreeURL, onOutput: onOutput)
        }
        if succeeded {
            ToastService.shared.showSuccess(title: "Tracking \(plan.remoteBranch)", message: skill.displayName)
        }
        await refresh()
        let skillsInTree = skills.filter { $0.gitWorkTreeURL == workTreeURL }
        statuses.merge(skillsInTree.map { ($0.id, .checking) }) { _, checking in checking }
        let results = await checkGitSkills(skillsInTree, environment: await resolvedEnvironment())
        statuses.merge(results) { _, new in new }
    }

    // MARK: - Updating

    func update(_ skill: Skill) async {
        guard status(of: skill).canUpdate else { return }
        let succeeded = await runOperation("Updating \(skill.displayName)") { environment, onOutput in
            switch skill.sourceKind {
            case .skillsCLI:
                return try await SkillsCLI(environment: environment).update([skill.folderName], onOutput: onOutput)
            case .git:
                guard let workTreeURL = skill.gitWorkTreeURL else { throw CommandError.failed("No git clone found.") }
                return try await GitClient(environment: environment).pull(workTree: workTreeURL, onOutput: onOutput)
            case .plugin, .local:
                throw CommandError.failed("\(skill.displayName) can't be updated here.")
            }
        }
        if succeeded {
            markUpToDate(skill.gitWorkTreeURL.map { workTreeURL in skills.filter { $0.gitWorkTreeURL == workTreeURL } } ?? [skill])
            ToastService.shared.showSuccess(title: "Updated", message: skill.displayName)
        }
        await refresh()
    }

    /// Every update the last check found.
    func updateAll() async {
        await update(skillsWithUpdates)
    }

    /// The given skills that have updates: one CLI run for all CLI skills, one pull per clone.
    func update(_ targetSkills: [Skill]) async {
        let pending = targetSkills.filter { status(of: $0).canUpdate }
        guard !pending.isEmpty else { return }
        let cliSkills = pending.filter { $0.sourceKind == .skillsCLI }
        let workTrees = Set(pending.compactMap { $0.sourceKind == .git ? $0.gitWorkTreeURL : nil })
        var updatedSkills: [Skill] = []

        if !cliSkills.isEmpty {
            let succeeded = await runOperation("Updating \(cliSkills.count) skills") { environment, onOutput in
                try await SkillsCLI(environment: environment).update(cliSkills.map(\.folderName), onOutput: onOutput)
            }
            if succeeded { updatedSkills += cliSkills }
        }
        let pulledTrees = await pull(workTrees.sorted { $0.path < $1.path })
        updatedSkills += skills.filter { $0.gitWorkTreeURL.map(pulledTrees.contains) ?? false }

        markUpToDate(updatedSkills)
        if !updatedSkills.isEmpty {
            ToastService.shared.showSuccess(title: "Updated \(updatedSkills.count) skill(s)", message: "Check the activity log for details.")
        }
        await refresh()
    }

    private func markUpToDate(_ updatedSkills: [Skill]) {
        statuses.merge(updatedSkills.map { ($0.id, .upToDate) }) { _, upToDate in upToDate }
    }

    // MARK: - Installing and removing

    func availableSkills(in input: SkillSourceInput) async throws -> [AvailableSkill] {
        let environment = await resolvedEnvironment()
        return try await SkillSourceBrowser(git: GitClient(environment: environment)).availableSkills(in: input)
    }

    /// Whether an agent already has a skill with this name.
    func isInstalled(named name: String) -> Bool {
        skills.contains { $0.sourceKind != .plugin && !$0.agents.isEmpty && ($0.displayName.caseInsensitiveCompare(name) == .orderedSame || $0.folderName.caseInsensitiveCompare(name) == .orderedSame) }
    }

    @discardableResult
    func install(source: String, skillNames: [String], agentKeys: [String]) async -> Bool {
        let succeeded = await runOperation("Installing \(skillNames.joined(separator: ", "))") { environment, onOutput in
            try await SkillsCLI(environment: environment).install(source: source, skillNames: skillNames, agentKeys: agentKeys, onOutput: onOutput)
        }
        if succeeded {
            ToastService.shared.showSuccess(title: "Installed", message: skillNames.joined(separator: ", "))
        }
        await refresh()
        return succeeded
    }

    /// Removes one skill from one agent, or from all of them when `agent` is nil.
    func remove(_ skill: Skill, from agent: SkillAgentInstall? = nil) async {
        await remove([skill], fromAgentNamed: agent?.displayName)
    }

    /// Every skill an agent has, for an agent you've stopped using.
    func removeAllSkills(fromAgentNamed agentName: String) async {
        await remove(skills.filter { $0.isInstalled(forAgentNamed: agentName) || $0.disabledAgentNames.contains(agentName) }, fromAgentNamed: agentName)
    }

    /// Removes skills from one agent, or from every agent when `agentName` is nil.
    /// CLI skills go through one `skills remove`; folders, clones and links go to
    /// the Trash, and so do copies Disable set aside. Plugin skills are skipped.
    func remove(_ targetSkills: [Skill], fromAgentNamed agentName: String?) async {
        let removable = targetSkills.filter(\.isRemovable)
        guard !removable.isEmpty else { return }
        let target = agentName ?? "every agent"
        var failures: [String] = []

        // Copies Disable moved aside: removing means they're not coming back.
        for skill in removable {
            for entry in skill.disabledEntries where agentName == nil || entry.agentNames.contains(agentName!) {
                do {
                    let store = disabledStore
                    try await runOffMain { try store.discard(entry) }
                    appendLog("Moved the disabled copy of \(skill.folderName) to the Trash.", type: .system)
                } catch {
                    failures.append("\(skill.displayName): \(error.localizedDescription)")
                }
            }
        }

        // Fully disabled CLI skills are still in the lock file; `skills remove` drops them from it.
        let cliSkills = removable.filter { skill in
            skill.sourceKind == .skillsCLI && (agentName == nil || skill.isInstalled(forAgentNamed: agentName!))
        }
        if !cliSkills.isEmpty {
            let agentKey = agentName.flatMap { AgentRegistry.definition(displayName: $0)?.key }
            if agentName != nil && agentKey == nil {
                failures.append("Skills Buddy doesn't know the --agent name for \(target).")
            } else {
                let succeeded = await runOperation("Removing \(cliSkills.count) skill(s) from \(target)") { environment, onOutput in
                    try await SkillsCLI(environment: environment).remove(cliSkills.map(\.folderName), agentKey: agentKey, onOutput: onOutput)
                }
                if !succeeded { failures.append(errorMessage ?? "skills remove failed.") }
            }
        }

        for skill in removable where skill.sourceKind != .skillsCLI {
            let installs = skill.agents.filter { agentName == nil || $0.displayName == agentName }
            // Agents can share a folder (Codex, Pi and Warp all read ~/.agents/skills).
            let folders = installs.compactMap(\.folderURL) + (agentName == nil ? [skill.folderURL] : [])
            var trashedPaths = Set<String>()
            for folderURL in folders where trashedPaths.insert(folderURL.standardizedFileURL.path).inserted {
                guard DisabledSkillStore.itemExists(at: folderURL) else { continue }
                do {
                    // A symlink goes to the Trash as a link; its target stays put.
                    try await runOffMain { try FileManager.default.trashItem(at: folderURL, resultingItemURL: nil) }
                    appendLog("Moved \(folderURL.path) to the Trash.", type: .system)
                } catch {
                    failures.append("Couldn't move \(folderURL.path) to the Trash: \(error.localizedDescription)")
                }
            }
        }

        if failures.isEmpty {
            let what = removable.count == 1 ? removable[0].displayName : "\(removable.count) skills"
            ToastService.shared.showSuccess(title: "Removed", message: "\(what) from \(target)")
        } else {
            errorMessage = failures.joined(separator: "\n")
        }
        await refresh()
    }

    // MARK: - Enabling and disabling

    private let disabledStore = DisabledSkillStore.standard

    /// Disables skills for one agent, or for every agent when `agentName` is
    /// nil, by moving each agent's entry out of its skills folder. Agents that
    /// read the same folder go with it.
    func disable(_ targetSkills: [Skill], forAgentNamed agentName: String? = nil) async {
        var failures: [String] = []
        var disabledCount = 0
        for skill in targetSkills where skill.isRemovable {
            let installs = skill.agents.filter { agentName == nil || $0.displayName == agentName }
            let paths = Set(installs.compactMap { $0.folderURL?.standardizedFileURL.path })
            if paths.isEmpty && !installs.isEmpty {
                failures.append("\(skill.displayName): couldn't find the agent's copy.")
            }
            for path in paths.sorted() {
                let agentsHere = skill.agents.filter { $0.folderURL?.standardizedFileURL.path == path }.map(\.displayName)
                do {
                    let store = disabledStore
                    let skillName = skill.folderName
                    _ = try await runOffMain { try store.disable(itemAt: URL(fileURLWithPath: path), skillName: skillName, agentNames: agentsHere) }
                    appendLog("Disabled \(skill.folderName) for \(agentsHere.joined(separator: ", ")).", type: .system)
                    disabledCount += 1
                } catch {
                    failures.append("\(skill.displayName): \(error.localizedDescription)")
                }
            }
        }
        finishToggle(verb: "Disabled", count: disabledCount, agentName: agentName, failures: failures)
        await refresh()
    }

    /// Puts disabled entries back for one agent, or for every agent when `agentName` is nil.
    func enable(_ targetSkills: [Skill], forAgentNamed agentName: String? = nil) async {
        var failures: [String] = []
        var enabledCount = 0
        for skill in targetSkills {
            for entry in skill.disabledEntries where agentName == nil || entry.agentNames.contains(agentName!) {
                do {
                    let store = disabledStore
                    try await runOffMain { try store.enable(entry) }
                    appendLog("Enabled \(skill.folderName) for \(entry.agentNames.joined(separator: ", ")).", type: .system)
                    enabledCount += 1
                } catch {
                    failures.append("\(skill.displayName): \(error.localizedDescription)")
                }
            }
        }
        finishToggle(verb: "Enabled", count: enabledCount, agentName: agentName, failures: failures)
        await refresh()
    }

    private func finishToggle(verb: String, count: Int, agentName: String?, failures: [String]) {
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        guard count > 0 else { return }
        let scope = agentName.map { " for \($0)" } ?? ""
        ToastService.shared.showSuccess(title: verb, message: "\(count) skill folder(s)\(scope).")
    }

    // MARK: - Attaching a repository

    /// Gives a skill with no recorded source one: reinstalls it from `source`
    /// with the `skills` CLI for the same agents, so updates come from there.
    /// The current copies are set aside first and go to the Trash once the
    /// install works, or back where they were if it fails.
    @discardableResult
    func attachRepository(to skill: Skill, source: String, sourceSkillName: String) async -> Bool {
        let agentKeys = skill.agents.compactMap(\.key)
        guard !agentKeys.isEmpty else {
            errorMessage = "\(skill.displayName) isn't installed for any agent Skills Buddy can name."
            return false
        }

        let backups = DisabledSkillStore(rootURL: disabledStore.rootURL.deletingLastPathComponent().appending(path: "AttachBackups", directoryHint: .isDirectory))
        var setAside: [DisabledSkillEntry] = []
        let paths = Set((skill.agents.compactMap(\.folderURL) + [skill.folderURL]).map { $0.standardizedFileURL.path })
        let skillName = skill.folderName
        do {
            for path in paths.sorted() where DisabledSkillStore.itemExists(at: URL(fileURLWithPath: path)) {
                setAside.append(try await runOffMain { try backups.disable(itemAt: URL(fileURLWithPath: path), skillName: skillName, agentNames: []) })
            }
        } catch {
            let entriesToRestore = setAside
            _ = try? await runOffMain { for entry in entriesToRestore { try? backups.enable(entry) } }
            errorMessage = "Couldn't set \(skill.displayName) aside: \(error.localizedDescription)"
            return false
        }

        let succeeded = await runOperation("Attaching \(source) to \(skill.displayName)") { environment, onOutput in
            try await SkillsCLI(environment: environment).install(source: source, skillNames: [sourceSkillName], agentKeys: agentKeys, onOutput: onOutput)
        }
        if succeeded {
            let entriesToDiscard = setAside
            _ = try? await runOffMain { for entry in entriesToDiscard { try? backups.discard(entry) } }
            appendLog("The previous copy of \(skill.folderName) is in the Trash.", type: .system)
            ToastService.shared.showSuccess(title: "Repository attached", message: "\(sourceSkillName) now updates from \(source).")
        } else {
            let entriesToRestore = setAside
            _ = try? await runOffMain { for entry in entriesToRestore { try? backups.enable(entry) } }
            appendLog("Put the previous copy of \(skill.folderName) back.", type: .system)
        }
        await refresh()
        return succeeded
    }

    // MARK: - History

    func history(for skill: Skill) async throws -> SkillHistory {
        let environment = await resolvedEnvironment()
        return try await SkillHistoryReader(git: GitClient(environment: environment)).history(for: skill)
    }

    /// Puts the skill's files back to `commit`.
    ///
    /// - Git clones reset to it; Update brings them back to the latest. Blocked
    ///   while the clone has uncommitted changes or commits the remote doesn't.
    /// - CLI skills reinstall from `source#commit` for the same agents, which
    ///   pins them; restoring the latest commit installs without a pin again.
    @discardableResult
    func restore(_ skill: Skill, to commit: String, isLatest: Bool) async -> Bool {
        let shortCommit = String(commit.prefix(7))
        let succeeded: Bool
        switch skill.sourceKind {
        case .git:
            guard let workTreeURL = skill.gitWorkTreeURL else { return false }
            let git = GitClient(environment: await resolvedEnvironment())
            do {
                if try await git.hasLocalChanges(workTree: workTreeURL) {
                    errorMessage = "\(skill.displayName)'s clone has uncommitted changes. Commit or discard them first."
                    return false
                }
                if (try? await git.commitsAhead(workTree: workTreeURL)) ?? 0 > 0 {
                    errorMessage = "\(skill.displayName)'s clone has commits that aren't on the remote. Push them first so restoring can't lose them."
                    return false
                }
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
            succeeded = await runOperation("Restoring \(skill.displayName) to \(shortCommit)") { _, onOutput in
                try await git.resetHard(workTree: workTreeURL, to: commit, onOutput: onOutput)
            }
            if succeeded {
                let restoredStatus: SkillUpdateStatus = isLatest ? .upToDate : .updateAvailable
                statuses.merge(skills.filter { $0.gitWorkTreeURL == workTreeURL }.map { ($0.id, restoredStatus) }) { _, restored in restored }
            }

        case .skillsCLI:
            guard let repository = skill.repository else { return false }
            let agentKeys = skill.agents.compactMap(\.key)
            guard !agentKeys.isEmpty else {
                errorMessage = "\(skill.displayName) isn't installed for any agent Skills Buddy can name."
                return false
            }
            succeeded = await runOperation("Restoring \(skill.displayName) to \(isLatest ? "the latest version" : shortCommit)") { environment, onOutput in
                try await SkillsCLI(environment: environment).install(
                    source: repository.location,
                    revision: isLatest ? nil : commit,
                    skillNames: [skill.displayName],
                    agentKeys: agentKeys,
                    onOutput: onOutput
                )
            }
            if succeeded { statuses[skill.id] = isLatest ? .upToDate : .pinned }

        case .plugin, .local:
            return false
        }

        if succeeded {
            ToastService.shared.showSuccess(title: "Restored", message: "\(skill.displayName) is at \(isLatest ? "the latest version" : shortCommit).")
        }
        await refresh()
        return succeeded
    }

    // MARK: - Running commands

    /// Runs one command, streaming its output into the activity log in order.
    /// Returns whether it exited successfully; failures land in `errorMessage`.
    private func runOperation(
        _ title: String,
        _ body: @escaping @Sendable (ShellEnvironment, @escaping @Sendable (CommandOutputLine) -> Void) async throws -> CommandResult
    ) async -> Bool {
        activeOperation = title
        defer { activeOperation = nil }
        appendLog(title + "…", type: .system)

        let environment = await resolvedEnvironment()
        let (lineStream, lineContinuation) = AsyncStream.makeStream(of: CommandOutputLine.self)
        let logConsumer = Task { @MainActor in
            for await line in lineStream { appendLog(line.text, type: line.isError ? .stderr : .stdout) }
        }

        let outcome: Result<CommandResult, Error>
        do {
            outcome = .success(try await body(environment) { line in lineContinuation.yield(line) })
        } catch {
            outcome = .failure(error)
        }
        lineContinuation.finish()
        await logConsumer.value

        switch outcome {
        case .success(let result) where result.succeeded:
            return true
        case .success(let result):
            errorMessage = "\(title) failed: \(result.failureSummary)"
        case .failure(let error):
            errorMessage = "\(title) failed: \(error.localizedDescription)"
        }
        appendLog(errorMessage ?? "\(title) failed.", type: .stderr)
        return false
    }

    /// Pulls several clones at once (they're separate repositories). Each log
    /// line is prefixed with its clone's folder when there's more than one.
    /// Returns the clones that pulled cleanly; failures land in `errorMessage`.
    private func pull(_ workTrees: [URL]) async -> Set<URL> {
        guard !workTrees.isEmpty else { return [] }
        let title = workTrees.count == 1 ? "Pulling \(workTrees[0].lastPathComponent)" : "Pulling \(workTrees.count) clones"
        activeOperation = title
        defer { activeOperation = nil }
        appendLog(title + "…", type: .system)

        let git = GitClient(environment: await resolvedEnvironment())
        let (lineStream, lineContinuation) = AsyncStream.makeStream(of: CommandOutputLine.self)
        let logConsumer = Task { @MainActor in
            for await line in lineStream { appendLog(line.text, type: line.isError ? .stderr : .stdout) }
        }
        let labelsLines = workTrees.count > 1
        let outcomes = await concurrentMap(workTrees) { workTreeURL -> (URL, String?) in
            let label = labelsLines ? "[\(workTreeURL.lastPathComponent)] " : ""
            do {
                let result = try await git.pull(workTree: workTreeURL) { line in
                    lineContinuation.yield(CommandOutputLine(text: label + line.text, isError: line.isError))
                }
                return (workTreeURL, result.succeeded ? nil : result.failureSummary)
            } catch {
                return (workTreeURL, error.localizedDescription)
            }
        }
        lineContinuation.finish()
        await logConsumer.value

        let failures = outcomes.compactMap { workTreeURL, failure in failure.map { "Pulling \(workTreeURL.lastPathComponent) failed: \($0)" } }
        for failure in failures { appendLog(failure, type: .stderr) }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        return Set(outcomes.compactMap { workTreeURL, failure in failure == nil ? workTreeURL : nil })
    }

    private func appendLog(_ text: String, type: TerminalOutputLine.OutputType) {
        activityLog.append(TerminalOutputLine(text, type: type))
        // Keep the log bounded over a long session.
        if activityLog.count > 2_000 { activityLog.removeFirst(activityLog.count - 2_000) }
    }

    func clearActivityLog() {
        activityLog.removeAll()
    }

    /// The login shell's environment, for services run outside the library (the repo finder).
    func resolvedEnvironment() async -> ShellEnvironment {
        if let environmentTask { return await environmentTask.value }
        let task = Task { await ShellEnvironment.resolve() }
        environmentTask = task
        return await task.value
    }
}
