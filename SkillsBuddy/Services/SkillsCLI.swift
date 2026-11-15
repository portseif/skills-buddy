//
//  SkillsCLI.swift
//  SkillsBuddy
//
//  Drives the `skills` CLI (vercel-labs/skills) through npx. The CLI knows
//  every agent's skills folder and owns `~/.agents/.skill-lock.json`; going
//  through it keeps both in sync.
//
//  Every call is global (`-g`) and non-interactive (`-y`). Installs and
//  removals name their agents with `--agent <key>` so nothing lands in, or
//  disappears from, an agent the user didn't pick.
//

import Foundation

/// One entry of `skills list -g --json`.
nonisolated struct ListedSkill: Decodable, Hashable, Sendable {
    let name: String
    /// The shared copy (or the first agent's folder); nil for a lock entry with no files.
    let path: String?
    /// Display names of the agents that load it (`Claude Code`, `Cursor`).
    let agents: [String]
    /// `tracked` (in the lock), `untracked`, or `missing`.
    let status: String?
}

nonisolated struct SkillsCLI: Sendable {
    let environment: ShellEnvironment

    /// Every global skill across every agent the CLI detects.
    @concurrent func listInstalledSkills() async throws -> [ListedSkill] {
        warnIfOnMainThread("SkillsCLI.listInstalledSkills")
        let result = try await run(["list", "-g", "--json"])
        guard result.succeeded else { throw CommandError.failed(result.failureSummary) }
        return try Self.parseListOutput(result.standardOutput)
    }

    /// Names of global skills with an update, from `skills check -g`.
    @concurrent func skillNamesWithUpdates() async throws -> Set<String> {
        let result = try await run(["check", "-g"])
        // `check` exits 1 when it found updates, so the exit code alone isn't a failure.
        let names = Self.parseCheckOutput(result.standardOutput)
        if !result.succeeded && names.isEmpty {
            throw CommandError.failed(result.failureSummary)
        }
        return names
    }

    /// Updates the named skills, or every global skill when `skillNames` is empty.
    @concurrent func update(_ skillNames: [String], onOutput: (@Sendable (CommandOutputLine) -> Void)? = nil) async throws -> CommandResult {
        try await run(["update"] + skillNames + ["-g", "-y"], onOutput: onOutput)
    }

    /// Installs skills from `source` (`owner/repo`, a git URL, or a GitHub tree
    /// URL) for `agentKeys`. A `revision` installs that commit and pins it in
    /// the lock (`source#commit`); installing without one follows the default
    /// branch again.
    @concurrent func install(
        source: String,
        revision: String? = nil,
        skillNames: [String],
        agentKeys: [String],
        onOutput: (@Sendable (CommandOutputLine) -> Void)? = nil
    ) async throws -> CommandResult {
        let sourceArgument = revision.map { "\(source)#\($0)" } ?? source
        let agentArguments = agentKeys.flatMap { ["--agent", $0] }
        let skillArguments = skillNames.flatMap { ["--skill", $0] }
        return try await run(["add", sourceArgument, "-g"] + agentArguments + skillArguments + ["-y"], onOutput: onOutput)
    }

    /// Removes skills from one agent, or from every agent when `agentKey` is
    /// nil (that also drops them from the lock file). The CLI keeps the
    /// shared copy while another agent still uses it.
    @concurrent func remove(_ skillNames: [String], agentKey: String?, onOutput: (@Sendable (CommandOutputLine) -> Void)? = nil) async throws -> CommandResult {
        let agentArguments = agentKey.map { ["--agent", $0] } ?? []
        return try await run(["remove"] + skillNames + ["-g"] + agentArguments + ["-y"], onOutput: onOutput)
    }

    static func parseListOutput(_ output: String) throws -> [ListedSkill] {
        // npm can print notices before the JSON; start at the array.
        guard let arrayStart = output.firstIndex(of: "[") else { return [] }
        return try JSONDecoder().decode([ListedSkill].self, from: Data(output[arrayStart...].utf8))
    }

    /// `skills check` prints one `↑ <name> has an update` line per outdated skill.
    static func parseCheckOutput(_ output: String) -> Set<String> {
        let plain = CommandRunner.stripANSI(output)
        var names = Set<String>()
        for line in plain.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let match = line.firstMatch(of: /↑\s+(.+?)\s+has an update/) else { continue }
            names.insert(String(match.output.1))
        }
        return names
    }

    @concurrent private func run(_ arguments: [String], onOutput: (@Sendable (CommandOutputLine) -> Void)? = nil) async throws -> CommandResult {
        guard let npxURL = environment.executableURL(named: "npx") else {
            throw CommandError.executableNotFound("npx")
        }
        return try await CommandRunner.run(
            executableURL: npxURL,
            arguments: ["--yes", "skills"] + arguments,
            // Run from home so the CLI never mistakes a project folder for the scope.
            workingDirectory: environment.homeDirectoryURL,
            environment: environment.variables,
            onOutput: onOutput
        )
    }
}
