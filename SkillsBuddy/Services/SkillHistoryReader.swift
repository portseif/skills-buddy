//
//  SkillHistoryReader.swift
//  SkillsBuddy
//
//  Reads a skill's commit history. Git skills read their own clone. CLI skills
//  keep no history on disk, so their source repo is cloned (blobless: commits
//  and trees, no file contents) into the app's cache and fetched on each read.
//

import Foundation

nonisolated enum SkillHistoryError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "This skill has no recorded source, so there's no history to show."
    }
}

nonisolated struct SkillHistoryReader: Sendable {
    let git: GitClient

    static let revisionLimit = 150

    /// `~/Library/Caches/io.portseif.SkillsBuddy/Repositories`.
    static var cacheDirectoryURL: URL {
        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return cachesURL.appending(path: "io.portseif.SkillsBuddy/Repositories", directoryHint: .isDirectory)
    }

    @concurrent func history(for skill: Skill) async throws -> SkillHistory {
        warnIfOnMainThread("SkillHistoryReader.history")
        guard let folderPath = skill.sourceFolderPath else { throw SkillHistoryError.unavailable }

        switch skill.sourceKind {
        case .git:
            guard let workTreeURL = skill.gitWorkTreeURL else { throw SkillHistoryError.unavailable }
            // The installed commit doesn't depend on the upstream; ask for both at once.
            async let upstreamCommit = git.resolveCommit("@{upstream}", workTree: workTreeURL)
            async let installedCommit = git.lastCommit(touching: folderPath, from: "HEAD", workTree: workTreeURL)
            let hasUpstream = await upstreamCommit != nil
            let tips = hasUpstream ? ["HEAD", "@{upstream}"] : ["HEAD"]
            async let history = git.history(workTree: workTreeURL, tips: tips, folderPath: folderPath, limit: Self.revisionLimit)
            async let latestCommit: String? = hasUpstream ? git.lastCommit(touching: folderPath, from: "@{upstream}", workTree: workTreeURL) : nil
            let (revisions, isTruncated) = try await history
            let installed = await installedCommit
            let latest = hasUpstream ? await latestCommit : installed
            return SkillHistory(revisions: revisions, installedCommitHash: installed, latestCommitHash: latest, isTruncated: isTruncated)

        case .skillsCLI:
            guard let repository = skill.repository else { throw SkillHistoryError.unavailable }
            let cacheURL = Self.cacheDirectoryURL.appending(path: Self.cacheFolderName(for: repository), directoryHint: .isDirectory)
            try await git.updateHistoryCache(cloneURL: repository.cloneURL, at: cacheURL)

            // The latest commit doesn't depend on the pin; ask for it alongside.
            async let latestCommit = git.lastCommit(touching: folderPath, from: "origin/HEAD", workTree: cacheURL)
            var tips = ["origin/HEAD"]
            if let pinnedRevision = skill.pinnedRevision, let pinnedCommit = await git.resolveCommit(pinnedRevision, workTree: cacheURL) {
                tips.append(pinnedCommit)
            }
            let (revisions, isTruncated) = try await git.history(workTree: cacheURL, tips: tips, folderPath: folderPath, limit: Self.revisionLimit)
            // The lock records the installed folder's tree hash, which is exact even
            // when several commits share a message or the skill was pinned.
            let installed = skill.installedTreeHash.flatMap { treeHash in
                revisions.first { $0.folderTreeHash == treeHash }?.commitHash
            }
            let latest = await latestCommit
            return SkillHistory(revisions: revisions, installedCommitHash: installed, latestCommitHash: latest, isTruncated: isTruncated)

        case .plugin, .local:
            throw SkillHistoryError.unavailable
        }
    }

    /// `vercel-labs/skills` → `vercel-labs--skills`.
    static func cacheFolderName(for repository: SkillRepository) -> String {
        String(repository.displayName.replacingOccurrences(of: "/", with: "--").map { character in
            character.isLetter || character.isNumber || "-._".contains(character) ? character : "-"
        })
    }
}
