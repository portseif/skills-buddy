//
//  SkillRepoMatcher.swift
//  SkillsBuddy
//
//  Finds the GitHub repository a local skill came from:
//
//  1. Search GitHub for SKILL.md files under the skill's name.
//  2. An identical file (same git hash) is an exact match. Copies sit in
//     mirrors and collections too, so the best-placed one wins: not a fork,
//     the most stars, the shallowest path.
//  3. Otherwise the closest few are read and compared. Mostly the same text
//     is another version of the same file. Partly the same goes to Apple
//     Intelligence, when it's on, to judge from the descriptions. Less is a
//     rewrite, or another skill with the same name.
//  4. When the name finds nothing, Apple Intelligence suggests search phrases
//     from the skill's own description.
//

import Foundation

/// What the matcher needs to know about a local skill.
nonisolated struct LocalSkillProfile: Sendable {
    let folderName: String
    let displayName: String
    let summary: String
    /// The local SKILL.md.
    let text: String
    /// git's hash of the local SKILL.md.
    let blobSHA: String

    /// Reads the skill's SKILL.md; nil when it can't be read.
    static func load(for skill: Skill) -> LocalSkillProfile? {
        guard let data = try? Data(contentsOf: skill.skillFileURL) else { return nil }
        return LocalSkillProfile(
            folderName: skill.folderName,
            displayName: skill.displayName,
            summary: skill.summary,
            text: String(decoding: data, as: UTF8.self),
            blobSHA: GitBlobHash.sha(of: data)
        )
    }
}

/// A repository found for a skill.
nonisolated struct RepoMatch: Hashable, Sendable, Identifiable {
    nonisolated enum Confidence: Int, Comparable, Sendable {
        /// Another version of the same SKILL.md, or one Apple Intelligence
        /// judged to be the same skill.
        case likely
        /// The very same SKILL.md.
        case exact

        static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let candidate: RepoCandidate
    let confidence: Confidence
    /// The skill's name in the repository, for `skills add --skill`.
    let skillName: String
    /// Why it matched, shown under the result.
    let reason: String
    /// Other repositories holding the same file (mirrors and collections).
    let otherCopies: Int
    let stars: Int?

    var id: String { candidate.id }
}

/// A candidate's name and description, as Apple Intelligence compares them.
nonisolated struct CandidateSummary: Sendable {
    let name: String
    let description: String
}

/// Judgment calls a language model can help with; nil or empty when it can't.
protocol RepoMatchAdvising: Sendable {
    /// Short phrases likely to appear in the skill's SKILL.md, to search with
    /// when its name finds nothing.
    func searchPhrases(for profile: LocalSkillProfile) async -> [String]
    /// Why the candidate is the same skill as the local one, or nil when it isn't.
    func sameSkill(as profile: LocalSkillProfile, candidate: CandidateSummary) async -> String?
}

nonisolated struct SkillRepoMatcher: Sendable {
    let search: GitHubSkillSearch
    let pacer: SearchPacer
    let advisor: (any RepoMatchAdvising)?

    /// How many near candidates are read and compared when there's no exact copy.
    private static let comparedCandidates = 4
    /// Text overlap from which a candidate is another version of the same SKILL.md.
    /// Measured: another version 0.94; rewrites and other skills 0.00 to 0.01.
    static let versionOverlap = 0.5
    /// Text overlap from which Apple Intelligence judges a candidate; below
    /// it, the candidate is a rewrite or another skill with the same name.
    static let relatedOverlap = 0.1

    /// The best match for the skill, or nil when none is good enough.
    @concurrent func match(for profile: LocalSkillProfile) async throws -> RepoMatch? {
        warnIfOnMainThread("SkillRepoMatcher.match")
        let names = [profile.folderName, profile.displayName].reduce(into: [String]()) { names, name in
            if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { names.append(name) }
        }
        var candidates: [RepoCandidate] = []
        for name in names {
            candidates += try await pacedSearch(name).filter { Self.isNamed($0, anyOf: names) }
        }
        if let exact = await exactMatch(in: candidates, for: profile) { return exact }

        // Nothing under its name: let Apple Intelligence suggest what to search for.
        var phraseCandidates: [RepoCandidate] = []
        if candidates.isEmpty, let advisor {
            for phrase in await advisor.searchPhrases(for: profile).prefix(2) {
                phraseCandidates += try await pacedSearch("\"\(phrase)\"")
            }
            if let exact = await exactMatch(in: phraseCandidates, for: profile) { return exact }
        }
        return await closestMatch(in: Self.unique(candidates + phraseCandidates), for: profile)
    }

    // MARK: - Exact copies

    /// The best-placed copy of the very same SKILL.md, if any.
    private func exactMatch(in candidates: [RepoCandidate], for profile: LocalSkillProfile) async -> RepoMatch? {
        let copies = Self.unique(candidates.filter { $0.blobSHA == profile.blobSHA })
        guard !copies.isEmpty else { return nil }
        let repositories = Array(Set(copies.map(\.repository))).sorted()
        let starCounts = await concurrentMap(repositories, limit: 4) { repository in (repository, await search.stars(of: repository)) }
        let stars = Dictionary(starCounts, uniquingKeysWith: { first, _ in first })
        let best = copies.sorted { Self.isBetterPlaced($0, than: $1, stars: stars) }[0]
        return RepoMatch(
            candidate: best,
            confidence: .exact,
            skillName: profile.displayName,
            reason: "Same SKILL.md",
            otherCopies: repositories.count - 1,
            stars: stars[best.repository] ?? nil
        )
    }

    /// Not a fork, then more stars, then a shallower path.
    static func isBetterPlaced(_ first: RepoCandidate, than second: RepoCandidate, stars: [String: Int?]) -> Bool {
        if first.isFork != second.isFork { return !first.isFork }
        let firstStars = (stars[first.repository] ?? nil) ?? 0
        let secondStars = (stars[second.repository] ?? nil) ?? 0
        if firstStars != secondStars { return firstStars > secondStars }
        if first.depth != second.depth { return first.depth < second.depth }
        return first.id < second.id
    }

    // MARK: - Close matches

    /// A candidate's SKILL.md, read and compared with the local one.
    private struct ReadCandidate: Sendable {
        let candidate: RepoCandidate
        let frontmatter: SkillFrontmatter
        let overlap: Double
    }

    /// The candidate that's the same skill though its SKILL.md differs (an
    /// older or newer version, or local edits), if one is close enough.
    private func closestMatch(in candidates: [RepoCandidate], for profile: LocalSkillProfile) async -> RepoMatch? {
        let shortlist = Array(candidates.sorted { Self.isBetterPlaced($0, than: $1, stars: [:]) }.prefix(Self.comparedCandidates))
        let readCandidates = await concurrentMap(shortlist, limit: 4) { candidate -> ReadCandidate? in
            guard let text = await search.fileText(repository: candidate.repository, path: candidate.path) else { return nil }
            return ReadCandidate(candidate: candidate, frontmatter: SkillFrontmatter.parse(text), overlap: Self.textOverlap(profile.text, text))
        }.compactMap { $0 }

        if let version = readCandidates.filter({ $0.overlap >= Self.versionOverlap }).max(by: { $0.overlap < $1.overlap }) {
            let matching = version.overlap.formatted(.percent.precision(.fractionLength(0)))
            return await likelyMatch(version, reason: "Another version of the same SKILL.md (\(matching) matches)")
        }
        guard let advisor else { return nil }
        // One at a time, best placed first: the small on-device model judges
        // a pair more reliably than it picks from a list.
        for read in readCandidates where read.overlap >= Self.relatedOverlap {
            let summary = CandidateSummary(name: read.frontmatter.name ?? read.candidate.folderName, description: read.frontmatter.description ?? "")
            if let reason = await advisor.sameSkill(as: profile, candidate: summary) {
                return await likelyMatch(read, reason: "Apple Intelligence: \(reason)")
            }
        }
        return nil
    }

    private func likelyMatch(_ read: ReadCandidate, reason: String) async -> RepoMatch {
        RepoMatch(
            candidate: read.candidate,
            confidence: .likely,
            skillName: read.frontmatter.name ?? read.candidate.folderName,
            reason: reason,
            otherCopies: 0,
            stars: await search.stars(of: read.candidate.repository)
        )
    }

    /// How much text two files share, from 0 to 1: the overlap of their
    /// five-word runs, so edits and reflowed lines still count as shared.
    static func textOverlap(_ first: String, _ second: String) -> Double {
        let firstRuns = wordRuns(in: first)
        let secondRuns = wordRuns(in: second)
        let union = firstRuns.union(secondRuns)
        guard !union.isEmpty else { return 0 }
        return Double(firstRuns.intersection(secondRuns).count) / Double(union.count)
    }

    private static func wordRuns(in text: String, length: Int = 5) -> Set<String> {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        guard words.count > length else { return words.isEmpty ? [] : [words.joined(separator: " ")] }
        return Set((0...(words.count - length)).map { words[$0..<($0 + length)].joined(separator: " ") })
    }

    // MARK: - Helpers

    /// Searches once the pacer allows, waiting out GitHub's limit once if it's hit anyway.
    private func pacedSearch(_ term: String) async throws -> [RepoCandidate] {
        try await pacer.waitTurn()
        do {
            return try await search.search(term)
        } catch GitHubSearchError.rateLimited {
            try await Task.sleep(for: .seconds(60))
            try await pacer.waitTurn()
            return try await search.search(term)
        }
    }

    /// Whether the candidate's folder (or, for a root SKILL.md, its repository) has one of the names.
    static func isNamed(_ candidate: RepoCandidate, anyOf names: [String]) -> Bool {
        let folder = candidate.folderName.isEmpty
            ? String(candidate.repository.split(separator: "/").last ?? "")
            : candidate.folderName
        return names.contains { $0.caseInsensitiveCompare(folder) == .orderedSame }
    }

    private static func unique(_ candidates: [RepoCandidate]) -> [RepoCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.id).inserted }
    }
}
