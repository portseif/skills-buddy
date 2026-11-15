//
//  GitTrackingTests.swift
//  SkillsBuddyTests
//
//  Track Remote Branch against real repositories in a temporary folder.
//

import Foundation
import Testing
@testable import Skills_Buddy

struct GitTrackingTests {
    private let rootURL = FileManager.default.temporaryDirectory.appending(path: "GitTrackingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let git = GitClient(environment: ShellEnvironment(variables: ["PATH": "/usr/bin:/bin"]))

    @discardableResult
    private func shell(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "init.defaultBranch=main"] + arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An origin with two commits on main, and a clone of it.
    private func makeCloneOfTwoCommits() throws -> (clone: URL, firstCommit: String) {
        let originURL = rootURL.appending(path: "origin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: originURL, withIntermediateDirectories: true)
        try shell(["init"], in: originURL)
        try "one".write(to: originURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try shell(["add", "."], in: originURL)
        try shell(["commit", "-m", "one"], in: originURL)
        let firstCommit = try shell(["rev-parse", "HEAD"], in: originURL)
        try "two".write(to: originURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try shell(["commit", "-am", "two"], in: originURL)

        let cloneURL = rootURL.appending(path: "clone", directoryHint: .isDirectory)
        try shell(["clone", originURL.path, cloneURL.path], in: rootURL)
        return (cloneURL, firstCommit)
    }

    @Test func aDetachedCloneSwitchesToTheDefaultBranchAndTracksIt() async throws {
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let (cloneURL, firstCommit) = try makeCloneOfTwoCommits()
        // Detached at the older commit, with the branch gone: like a release checkout.
        try shell(["checkout", "--detach", firstCommit], in: cloneURL)
        try shell(["branch", "-D", "main"], in: cloneURL)

        let plan = try #require(await git.trackingPlan(workTree: cloneURL))
        #expect(plan.currentBranch == nil)
        #expect(plan.remoteBranch == "origin/main")
        #expect(plan.localBranch == "main")
        #expect(plan.commitsBehind == 1)

        let result = try await git.trackRemoteBranch(plan, workTree: cloneURL)
        #expect(result.succeeded)
        #expect(try shell(["rev-parse", "--abbrev-ref", "main@{upstream}"], in: cloneURL) == "origin/main")
        #expect(try String(contentsOf: cloneURL.appendingPathComponent("SKILL.md"), encoding: .utf8) == "two")
        #expect(try await git.status(workTree: cloneURL).commitsBehind == 0)
    }

    @Test func aBranchWithoutUpstreamOnlyGetsOne() async throws {
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let (cloneURL, _) = try makeCloneOfTwoCommits()
        try shell(["branch", "--unset-upstream"], in: cloneURL)
        let headBefore = try shell(["rev-parse", "HEAD"], in: cloneURL)

        let plan = try #require(await git.trackingPlan(workTree: cloneURL))
        #expect(plan.currentBranch == "main")
        #expect(!plan.movesHead)

        _ = try await git.trackRemoteBranch(plan, workTree: cloneURL)
        #expect(try shell(["rev-parse", "HEAD"], in: cloneURL) == headBefore)
        #expect(try shell(["rev-parse", "--abbrev-ref", "main@{upstream}"], in: cloneURL) == "origin/main")
    }
}
