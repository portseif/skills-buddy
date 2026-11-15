//
//  GitClient.swift
//  SkillsBuddy
//
//  The git commands the app needs for skills that are git clones, plus a
//  shallow clone for previewing a repo before installing from it.
//

import Foundation

nonisolated struct GitWorkTreeStatus: Sendable {
    let commitsBehind: Int
    let hasLocalChanges: Bool
}

/// How a clone without an upstream would start tracking a remote branch.
nonisolated struct GitTrackingPlan: Equatable, Sendable {
    /// The branch HEAD is on, or nil when HEAD is detached.
    let currentBranch: String?
    /// The remote branch to follow, like `origin/main`.
    let remoteBranch: String
    /// Commits the remote branch has that HEAD doesn't.
    let commitsBehind: Int

    /// The local branch that will track `remoteBranch`.
    var localBranch: String {
        currentBranch ?? String(remoteBranch.split(separator: "/", maxSplits: 1).last ?? Substring(remoteBranch))
    }

    /// Detached, HEAD moves to the branch, and the files with it.
    var movesHead: Bool { currentBranch == nil }
}

nonisolated enum GitError: LocalizedError {
    case commandFailed(String)
    case noUpstream

    var errorDescription: String? {
        switch self {
        case .commandFailed(let summary): summary
        case .noUpstream: "This clone's branch doesn't track a remote branch."
        }
    }
}

nonisolated struct GitClient: Sendable {
    let environment: ShellEnvironment

    private var gitURL: URL {
        environment.executableURL(named: "git") ?? URL(fileURLWithPath: "/usr/bin/git")
    }

    /// The root of the git work tree containing `folderURL`, without leaving
    /// the home folder (so a dotfiles repo at `~` doesn't claim every skill).
    static func workTreeRoot(containing folderURL: URL, homeDirectoryURL: URL) -> URL? {
        let homePath = homeDirectoryURL.standardizedFileURL.path
        var candidate = folderURL.standardizedFileURL
        while candidate.path.hasPrefix(homePath + "/") {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    @concurrent func remoteURL(workTree: URL) async -> String? {
        await output(["config", "--get", "remote.origin.url"], workTree: workTree)
    }

    @concurrent func shortHead(workTree: URL) async -> String? {
        await output(["rev-parse", "--short", "HEAD"], workTree: workTree)
    }

    /// Fetches, then counts commits the upstream has that HEAD doesn't.
    @concurrent func status(workTree: URL) async throws -> GitWorkTreeStatus {
        let fetch = try await run(["fetch", "--quiet"], workTree: workTree)
        guard fetch.succeeded else { throw GitError.commandFailed(fetch.failureSummary) }

        let behind = try await run(["rev-list", "--count", "HEAD..@{upstream}"], workTree: workTree)
        guard behind.succeeded else { throw GitError.noUpstream }

        let porcelain = try await run(["status", "--porcelain"], workTree: workTree)
        guard porcelain.succeeded else { throw GitError.commandFailed(porcelain.failureSummary) }

        return GitWorkTreeStatus(
            commitsBehind: Int(behind.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
            hasLocalChanges: !porcelain.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    /// Fast-forward only: never creates a merge or touches local commits.
    @concurrent func pull(workTree: URL, onOutput: (@Sendable (CommandOutputLine) -> Void)? = nil) async throws -> CommandResult {
        try await run(["pull", "--ff-only"], workTree: workTree, onOutput: onOutput)
    }

    // MARK: - History

    /// Commits on `tips` that changed `folderPath` ("" for the whole repo),
    /// newest first in topological order, with parents rewritten to the
    /// nearest commits that also changed it. One extra commit is read to know
    /// whether the list was cut off.
    @concurrent func history(workTree: URL, tips: [String], folderPath: String, limit: Int) async throws -> (revisions: [SkillRevision], isTruncated: Bool) {
        let format = "--format=%H%x1f%P%x1f%an%x1f%aI%x1f%D%x1f%s%x1f%b%x1e"
        let pathArguments = folderPath.isEmpty ? [] : ["--", folderPath]
        let result = try await run(
            ["log", "--topo-order", "--parents", "--decorate=short", "-n", String(limit + 1), format] + tips + pathArguments,
            workTree: workTree
        )
        guard result.succeeded else { throw GitError.commandFailed(result.failureSummary) }
        var revisions = SkillHistory.parseLog(result.standardOutput)
        // Parents past the cut point keep their lanes running off the bottom.
        let isTruncated = revisions.count > limit
        if isTruncated { revisions.removeLast(revisions.count - limit) }

        let treeHashes = try await folderTreeHashes(workTree: workTree, commits: revisions.map(\.commitHash), folderPath: folderPath)
        for index in revisions.indices {
            revisions[index].folderTreeHash = treeHashes[revisions[index].commitHash]
        }
        return (revisions, isTruncated)
    }

    /// The tree hash of `folderPath` at each commit, in one `cat-file` call.
    /// A commit where the folder doesn't exist is left out.
    @concurrent func folderTreeHashes(workTree: URL, commits: [String], folderPath: String) async throws -> [String: String] {
        guard !commits.isEmpty else { return [:] }
        let objectNames = commits.map { folderPath.isEmpty ? "\($0)^{tree}" : "\($0):\(folderPath)" }
        let result = try await run(
            ["cat-file", "--batch-check=%(objectname) %(objecttype)"],
            workTree: workTree,
            standardInput: Data((objectNames.joined(separator: "\n") + "\n").utf8)
        )
        guard result.succeeded else { throw GitError.commandFailed(result.failureSummary) }
        let lines = result.standardOutput.split(separator: "\n", omittingEmptySubsequences: false)
        var hashes: [String: String] = [:]
        for (commit, line) in zip(commits, lines) {
            let parts = line.split(separator: " ")
            if parts.count == 2, parts[1] == "tree" { hashes[commit] = String(parts[0]) }
        }
        return hashes
    }

    /// The full hash `revision` names, or nil when it doesn't resolve to a commit.
    @concurrent func resolveCommit(_ revision: String, workTree: URL) async -> String? {
        await output(["rev-parse", "--verify", "--quiet", "\(revision)^{commit}"], workTree: workTree)
    }

    /// The newest commit reachable from `tip` that changed `folderPath`.
    @concurrent func lastCommit(touching folderPath: String, from tip: String, workTree: URL) async -> String? {
        await output(["log", "-1", "--format=%H", tip] + (folderPath.isEmpty ? [] : ["--", folderPath]), workTree: workTree)
    }

    /// The remote branch a clone without an upstream should track: the one
    /// named like its current branch, else the remote's default (`origin/HEAD`,
    /// then `origin/main`, `origin/master`). Nil when there's none.
    @concurrent func trackingPlan(workTree: URL) async -> GitTrackingPlan? {
        let currentBranch = await output(["symbolic-ref", "--quiet", "--short", "HEAD"], workTree: workTree)
        var remoteBranch: String?
        if let currentBranch, await resolveCommit("refs/remotes/origin/\(currentBranch)", workTree: workTree) != nil {
            remoteBranch = "origin/\(currentBranch)"
        }
        if remoteBranch == nil {
            remoteBranch = await output(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], workTree: workTree)
        }
        if remoteBranch == nil {
            for candidate in ["origin/main", "origin/master"] where await resolveCommit("refs/remotes/\(candidate)", workTree: workTree) != nil {
                remoteBranch = candidate
                break
            }
        }
        guard let remoteBranch else { return nil }
        let behind = await output(["rev-list", "--count", "HEAD..\(remoteBranch)"], workTree: workTree)
        return GitTrackingPlan(currentBranch: currentBranch, remoteBranch: remoteBranch, commitsBehind: behind.flatMap(Int.init) ?? 0)
    }

    /// Makes the clone follow `plan.remoteBranch`. On a branch, only its
    /// upstream changes. Detached, it switches to the local branch for it,
    /// creating one that tracks the remote branch when there isn't one.
    @concurrent func trackRemoteBranch(_ plan: GitTrackingPlan, workTree: URL, onOutput: (@Sendable (CommandOutputLine) -> Void)? = nil) async throws -> CommandResult {
        if plan.movesHead {
            if await resolveCommit("refs/heads/\(plan.localBranch)", workTree: workTree) == nil {
                return try await run(["switch", "--track", plan.remoteBranch], workTree: workTree, onOutput: onOutput)
            }
            let switched = try await run(["switch", plan.localBranch], workTree: workTree, onOutput: onOutput)
            guard switched.succeeded else { return switched }
        }
        return try await run(["branch", "--set-upstream-to=\(plan.remoteBranch)", plan.localBranch], workTree: workTree, onOutput: onOutput)
    }

    /// Commits on HEAD that the upstream doesn't have.
    @concurrent func commitsAhead(workTree: URL) async throws -> Int {
        let result = try await run(["rev-list", "--count", "@{upstream}..HEAD"], workTree: workTree)
        guard result.succeeded else { throw GitError.noUpstream }
        return Int(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    @concurrent func hasLocalChanges(workTree: URL) async throws -> Bool {
        let result = try await run(["status", "--porcelain"], workTree: workTree)
        guard result.succeeded else { throw GitError.commandFailed(result.failureSummary) }
        return !result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Moves the clone's branch to `commit`. Callers check for local changes
    /// and unpushed commits first; this overwrites both.
    @concurrent func resetHard(workTree: URL, to commit: String, onOutput: (@Sendable (CommandOutputLine) -> Void)? = nil) async throws -> CommandResult {
        try await run(["reset", "--hard", commit], workTree: workTree, onOutput: onOutput)
    }

    /// A blobless clone for reading history: commits and trees, no file contents.
    /// Fetches when it already exists.
    @concurrent func updateHistoryCache(cloneURL: String, at cacheURL: URL) async throws {
        if FileManager.default.fileExists(atPath: cacheURL.appendingPathComponent(".git").path) {
            let fetch = try await run(["fetch", "--quiet", "--prune", "--tags", "origin"], workTree: cacheURL)
            guard fetch.succeeded else { throw GitError.commandFailed(fetch.failureSummary) }
            return
        }
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = try await CommandRunner.run(
            executableURL: gitURL,
            arguments: ["clone", "--filter=blob:none", "--no-checkout", "--quiet", cloneURL, cacheURL.path],
            environment: nonInteractiveEnvironment
        )
        guard result.succeeded else { throw GitError.commandFailed(result.failureSummary) }
    }

    @concurrent func shallowClone(_ repositoryURL: String, branch: String? = nil, into destinationURL: URL) async throws {
        let branchArguments = branch.map { ["--branch", $0] } ?? []
        let result = try await CommandRunner.run(
            executableURL: gitURL,
            arguments: ["clone", "--depth", "1", "--quiet"] + branchArguments + [repositoryURL, destinationURL.path],
            environment: nonInteractiveEnvironment
        )
        guard result.succeeded else { throw GitError.commandFailed(result.failureSummary) }
    }

    // MARK: - Running

    /// Never let git stop and wait for a password prompt nobody can see.
    private var nonInteractiveEnvironment: [String: String] {
        var variables = environment.variables
        variables["GIT_TERMINAL_PROMPT"] = "0"
        return variables
    }

    @concurrent private func run(
        _ arguments: [String],
        workTree: URL,
        standardInput: Data? = nil,
        onOutput: (@Sendable (CommandOutputLine) -> Void)? = nil
    ) async throws -> CommandResult {
        try await CommandRunner.run(
            executableURL: gitURL,
            arguments: ["-C", workTree.path] + arguments,
            environment: nonInteractiveEnvironment,
            standardInput: standardInput,
            onOutput: onOutput
        )
    }

    @concurrent private func output(_ arguments: [String], workTree: URL) async -> String? {
        guard let result = try? await run(arguments, workTree: workTree), result.succeeded else { return nil }
        let text = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
