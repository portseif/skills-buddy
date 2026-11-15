//
//  SkillHistory.swift
//  SkillsBuddy
//
//  The commits that changed a skill's folder, newest first, with which one is
//  installed. Read from the skill's own clone, or for CLI skills from a cached
//  clone of the source repo.
//

import Foundation

nonisolated struct SkillRevision: Identifiable, Hashable, Sendable {
    let commitHash: String
    /// Rewritten to the nearest commits that also touched the folder.
    let parentHashes: [String]
    let title: String
    let authorName: String
    let date: Date
    /// Branches and tags pointing at this commit (`origin/main`, `tag: v1.0.0`).
    let decorations: [String]
    /// Tree hash of the skill folder at this commit; matches the CLI lock's `skillFolderHash`.
    var folderTreeHash: String?

    var id: String { commitHash }
    var shortHash: String { String(commitHash.prefix(7)) }
}

nonisolated struct SkillHistory: Sendable {
    /// Topological order, newest first.
    let revisions: [SkillRevision]
    /// The revision whose files are installed; nil when they match none (edited by hand).
    let installedCommitHash: String?
    /// The newest revision on the source's default branch.
    let latestCommitHash: String?
    /// More commits exist beyond `revisions`.
    let isTruncated: Bool

    /// Parses `git log --format=%H%x1f%P%x1f%an%x1f%aI%x1f%D%x1f%s%x1f%b%x1e`.
    /// A GitHub merge commit ("Merge pull request #12 from …") shows its pull
    /// request's title, the first line of the body, instead.
    static func parseLog(_ output: String) -> [SkillRevision] {
        output.split(separator: "\u{1E}").compactMap { record in
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1F}")
            guard fields.count >= 7, !fields[0].isEmpty else { return nil }
            let subject = fields[5].trimmingCharacters(in: .whitespaces)
            let bodyFirstLine = fields[6].split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            let isPullRequestMerge = subject.hasPrefix("Merge pull request #")
            let date = (try? Date(fields[3], strategy: .iso8601)) ?? .distantPast
            return SkillRevision(
                commitHash: fields[0],
                parentHashes: fields[1].split(separator: " ").map(String.init),
                title: isPullRequestMerge && !bodyFirstLine.isEmpty ? bodyFirstLine : subject,
                authorName: fields[2],
                date: date,
                decorations: parseDecorations(fields[4])
            )
        }
    }

    /// `HEAD -> main, origin/main, origin/HEAD, tag: v1.0` → `main, origin/main, tag: v1.0`.
    static func parseDecorations(_ text: String) -> [String] {
        text.split(separator: ",").compactMap { part in
            var decoration = part.trimmingCharacters(in: .whitespaces)
            if decoration.hasPrefix("HEAD -> ") { decoration.removeFirst("HEAD -> ".count) }
            guard !decoration.isEmpty, decoration != "HEAD", !decoration.hasSuffix("/HEAD") else { return nil }
            return decoration
        }
    }
}
