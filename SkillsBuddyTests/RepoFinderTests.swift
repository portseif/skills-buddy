//
//  RepoFinderTests.swift
//  SkillsBuddyTests
//

import Foundation
import Testing
@testable import Skills_Buddy

struct RepoFinderTests {
    @Test func blobHashMatchesGit() {
        // `printf 'hello\n' | git hash-object --stdin`
        #expect(GitBlobHash.sha(of: Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a")
        #expect(GitBlobHash.sha(of: Data()) == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    }

    @Test func decodesSearchResults() throws {
        let json = """
            [{"path":"skills/humanizer/SKILL.md","sha":"abc123","repository":{"nameWithOwner":"owner/repo","isFork":false}},
             {"path":"SKILL.md","sha":"def456","repository":{"nameWithOwner":"other/humanizer","isFork":true}}]
            """
        let candidates = try GitHubSkillSearch.decodeSearchResults(Data(json.utf8))
        #expect(candidates.count == 2)
        #expect(candidates[0].repository == "owner/repo")
        #expect(candidates[0].folderName == "humanizer")
        #expect(candidates[1].folderName == "")
        #expect(candidates[1].isFork)
    }

    @Test func aRootSkillIsNamedAfterItsRepository() {
        let root = RepoCandidate(repository: "someone/humanizer", path: "SKILL.md", blobSHA: "", isFork: false)
        let nested = RepoCandidate(repository: "someone/skills", path: "skills/humanizer/SKILL.md", blobSHA: "", isFork: false)
        let other = RepoCandidate(repository: "someone/skills", path: "skills/fb-humanizer/SKILL.md", blobSHA: "", isFork: false)
        #expect(SkillRepoMatcher.isNamed(root, anyOf: ["Humanizer"]))
        #expect(SkillRepoMatcher.isNamed(nested, anyOf: ["humanizer"]))
        #expect(!SkillRepoMatcher.isNamed(other, anyOf: ["humanizer"]))
    }

    @Test func theOriginalOutranksForksMirrorsAndDeepCopies() {
        let original = RepoCandidate(repository: "author/skills", path: "skills/x/SKILL.md", blobSHA: "", isFork: false)
        let fork = RepoCandidate(repository: "fan/skills", path: "skills/x/SKILL.md", blobSHA: "", isFork: true)
        let collection = RepoCandidate(repository: "list/awesome", path: "plugins/a/skills/x/SKILL.md", blobSHA: "", isFork: false)
        let stars: [String: Int?] = ["author/skills": 120, "fan/skills": 900, "list/awesome": 120]
        let ranked = [fork, collection, original].sorted { SkillRepoMatcher.isBetterPlaced($0, than: $1, stars: stars) }
        #expect(ranked.map(\.repository) == ["author/skills", "list/awesome", "fan/skills"])
    }

    @Test func textOverlapSeparatesVersionsFromRewrites() {
        let original = """
            ---
            name: humanizer
            description: Rewrite AI sounding text so it reads like the writer.
            ---
            Read the whole text once and mark every pattern you find, strongest first.
            Keep every supported claim, then rewrite each flagged sentence plainly.
            Vary sentence length and return only the final text in embedded mode.
            """
        let newerVersion = original.replacingOccurrences(of: "strongest first", with: "strongest first, then weakest")
        let rewrite = """
            ---
            name: humanizer
            description: Make prose sound human; use for drafts and posts.
            ---
            Follow GUIDE.md for the domain guidance.
            """
        #expect(SkillRepoMatcher.textOverlap(original, original) == 1)
        #expect(SkillRepoMatcher.textOverlap(original, newerVersion) >= SkillRepoMatcher.versionOverlap)
        #expect(SkillRepoMatcher.textOverlap(original, rewrite) < SkillRepoMatcher.relatedOverlap)
        #expect(SkillRepoMatcher.textOverlap("", "") == 0)
    }

    @Test func onlyLocalSkillsForAnAgentAreSearched() {
        let samples = Skill.previewSamples
        #expect(samples.filter(RepoFinder.isEligible).map(\.folderName) == ["meeting-notes"])
    }

    @Test func thePacerSpacesSearches() async throws {
        let pacer = SearchPacer(interval: .milliseconds(40))
        let start = ContinuousClock.now
        try await pacer.waitTurn()
        try await pacer.waitTurn()
        try await pacer.waitTurn()
        #expect(ContinuousClock.now - start >= .milliseconds(80))
    }
}
