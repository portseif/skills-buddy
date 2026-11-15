//
//  Skill.swift
//  SkillsBuddy
//
//  One installed skill and where it came from.
//

import Foundation

/// How a skill got onto the machine, which decides how it can be updated.
nonisolated enum SkillSourceKind: String, CaseIterable, Hashable, Sendable {
    /// Installed by the `skills` CLI and tracked in `~/.agents/.skill-lock.json`.
    case skillsCLI
    /// The skill folder (or its symlink target) is inside a git clone.
    case git
    /// Bundled in a Claude Code plugin. Read-only here: Claude Code updates plugins.
    case plugin
    /// A plain folder with no recorded source.
    case local

    var title: String {
        switch self {
        case .skillsCLI: "Skills CLI"
        case .git: "Git"
        case .plugin: "Plugin"
        case .local: "Local"
        }
    }

    var systemImage: String {
        switch self {
        case .skillsCLI: "shippingbox"
        case .git: "arrow.triangle.branch"
        case .plugin: "puzzlepiece.extension"
        case .local: "folder"
        }
    }
}

/// The repository a skill was installed from.
nonisolated struct SkillRepository: Hashable, Sendable {
    /// Clone URL or `owner/repo` shorthand, as recorded by the installer.
    let location: String

    /// `owner/repo` for GitHub URLs, otherwise the location without its scheme.
    var displayName: String {
        var trimmed = location
        for prefix in ["https://github.com/", "http://github.com/", "git@github.com:"] where trimmed.hasPrefix(prefix) {
            trimmed.removeFirst(prefix.count)
        }
        if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }
        if let schemeRange = trimmed.range(of: "://") { trimmed = String(trimmed[schemeRange.upperBound...]) }
        return trimmed
    }

    /// Something `git clone` accepts: shorthand expands to GitHub.
    var cloneURL: String {
        let isShorthand = location.split(separator: "/").count == 2 && !location.contains(":")
        return isShorthand ? "https://github.com/\(location).git" : location
    }

    /// A browsable web URL, when the location is (or expands to) an http(s) URL.
    var webURL: URL? {
        if location.hasPrefix("http://") || location.hasPrefix("https://") {
            return URL(string: location.hasSuffix(".git") ? String(location.dropLast(4)) : location)
        }
        if location.hasPrefix("git@github.com:") {
            return URL(string: "https://github.com/" + displayName)
        }
        let isShorthand = location.split(separator: "/").count == 2 && !location.contains(":")
        return isShorthand ? URL(string: "https://github.com/" + location) : nil
    }
}

nonisolated struct Skill: Identifiable, Hashable, Sendable {
    /// Stable across disabling, re-enabling and attaching a repo, which change
    /// its folder and source. Agent skills are unique by name (the CLI lists
    /// each name once across agents); a plugin's can repeat one, so they add
    /// the plugin.
    var id: String {
        if let pluginIdentifier { return "plugin:\(pluginIdentifier):\(folderName)" }
        return "skill:\(folderName)"
    }

    /// The folder name. The `skills` CLI and every agent's skills folder key skills by it.
    let folderName: String
    /// The frontmatter `name`, falling back to the folder name.
    let displayName: String
    /// The frontmatter `description`.
    let summary: String
    /// The folder as found (may be a symlink). For CLI skills, the shared copy.
    let folderURL: URL
    /// The folder after resolving symlinks, where the files actually live.
    let resolvedFolderURL: URL
    let sourceKind: SkillSourceKind
    let repository: SkillRepository?
    let installedAt: Date?
    let updatedAt: Date?
    /// The agents that load this skill, by display name order.
    let agents: [SkillAgentInstall]
    /// `name@marketplace` for plugin skills.
    let pluginIdentifier: String?
    /// Plugin version, or the short commit of a git clone.
    let version: String?
    /// The clone's root for `.git` skills; one pull updates every skill inside it.
    let gitWorkTreeURL: URL?
    /// Whether there's a recorded source to check for updates against.
    let isUpdateTracked: Bool
    /// The skill's folder inside its source repo ("" when the repo root is the skill).
    let sourceFolderPath: String?
    /// CLI skills: git tree hash of the installed folder, from the lock file.
    let installedTreeHash: String?
    /// CLI skills: the commit it was pinned to by restoring an older version.
    let pinnedRevision: String?
    /// Agents' entries moved aside by Disable, waiting to be put back.
    var disabledEntries: [DisabledSkillEntry] = []

    var isSymlink: Bool { folderURL.standardizedFileURL.path != resolvedFolderURL.standardizedFileURL.path }

    var skillFileURL: URL { resolvedFolderURL.appendingPathComponent("SKILL.md") }

    /// Plugin skills belong to Claude Code's plugin system, so they're read-only here.
    var isRemovable: Bool { sourceKind != .plugin }

    /// Disabled for every agent that had it: no agent loads it now.
    var isFullyDisabled: Bool { agents.isEmpty && !disabledEntries.isEmpty }

    /// The agents it's disabled for.
    var disabledAgentNames: [String] { disabledEntries.flatMap(\.agentNames).sorted() }

    /// Git clones and CLI skills from a git source have commits to show.
    var hasHistory: Bool {
        switch sourceKind {
        case .git: gitWorkTreeURL != nil
        case .skillsCLI: repository != nil && sourceFolderPath != nil && isUpdateTracked
        case .plugin, .local: false
        }
    }

    func isInstalled(forAgentNamed agentName: String) -> Bool {
        agents.contains { $0.displayName == agentName }
    }
}

/// What the last update check found for a skill.
nonisolated enum SkillUpdateStatus: Hashable, Sendable {
    case unchecked
    case checking
    case upToDate
    case updateAvailable
    /// A git clone with uncommitted changes. Updating would overwrite them, so it's blocked.
    case locallyModified
    /// No source to check against (plain folder, or a CLI entry without version tracking).
    case notTracked
    /// Claude Code updates plugins; nothing to do here.
    case managedByPlugin
    /// A CLI skill restored to an older commit; `skills update` leaves it there.
    case pinned
    /// Moved out of every agent's skills folder by Disable.
    case disabled
    /// A git clone whose branch follows no remote branch (or whose HEAD is
    /// detached), so there's nothing to compare against until it tracks one.
    case noUpstream
    case failed(String)

    var title: String {
        switch self {
        case .unchecked: "Not checked"
        case .checking: "Checking…"
        case .upToDate: "Up to date"
        case .updateAvailable: "Update available"
        case .locallyModified: "Local changes"
        case .notTracked: "Not tracked"
        case .managedByPlugin: "Via plugin"
        case .pinned: "Pinned"
        case .disabled: "Disabled"
        case .noUpstream: "No upstream"
        case .failed: "Check failed"
        }
    }

    var canUpdate: Bool { self == .updateAvailable }
}
