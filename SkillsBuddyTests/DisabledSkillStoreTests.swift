//
//  DisabledSkillStoreTests.swift
//  SkillsBuddyTests
//

import Foundation
import Testing
@testable import Skills_Buddy

struct DisabledSkillStoreTests {
    private let rootURL = FileManager.default.temporaryDirectory.appending(path: "DisabledSkillStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private var store: DisabledSkillStore {
        DisabledSkillStore(rootURL: rootURL.appending(path: "Disabled", directoryHint: .isDirectory))
    }

    private func makeSkillFolder(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "---\nname: sample\n---\n".write(to: url.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    @Test func disableAndEnableRoundTripsAFolder() throws {
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let skillURL = rootURL.appending(path: "agent/skills/sample", directoryHint: .isDirectory)
        try makeSkillFolder(at: skillURL)

        let entry = try store.disable(itemAt: skillURL, skillName: "sample", agentNames: ["Claude Code"])
        #expect(!FileManager.default.fileExists(atPath: skillURL.path))
        // By id: the manifest keeps whole-second dates, and the store matches entries by id.
        #expect(store.entries().map(\.id) == [entry.id])
        #expect(store.entries().first?.originalPath == skillURL.path)
        #expect(store.skillFolder(of: entry)?.lastPathComponent == "sample")

        try store.enable(entry)
        #expect(FileManager.default.fileExists(atPath: skillURL.appendingPathComponent("SKILL.md").path))
        #expect(store.entries().isEmpty)
    }

    @Test func symlinkMovesAsALinkAndStillResolves() throws {
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sharedURL = rootURL.appending(path: "shared/sample", directoryHint: .isDirectory)
        try makeSkillFolder(at: sharedURL)
        let linkURL = rootURL.appending(path: "agent/skills/sample")
        try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "../../shared/sample")

        let entry = try store.disable(itemAt: linkURL, skillName: "sample", agentNames: ["Cursor"])
        // The shared folder stays; only the agent's link moved.
        #expect(FileManager.default.fileExists(atPath: sharedURL.path))
        #expect(store.skillFolder(of: entry)?.standardizedFileURL.path == sharedURL.standardizedFileURL.path)

        try store.enable(entry)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path) == "../../shared/sample")
    }

    @Test func enableRefusesToOverwriteSomethingNew() throws {
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let skillURL = rootURL.appending(path: "agent/skills/sample", directoryHint: .isDirectory)
        try makeSkillFolder(at: skillURL)
        let entry = try store.disable(itemAt: skillURL, skillName: "sample", agentNames: ["Claude Code"])
        try makeSkillFolder(at: skillURL)

        #expect(throws: DisabledSkillError.self) { try store.enable(entry) }
        #expect(store.entries().count == 1)
    }

    @Test func discardForgetsTheEntry() throws {
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let skillURL = rootURL.appending(path: "agent/skills/sample", directoryHint: .isDirectory)
        try makeSkillFolder(at: skillURL)
        let entry = try store.disable(itemAt: skillURL, skillName: "sample", agentNames: ["Claude Code"])

        try store.discard(entry)
        #expect(store.entries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: entry.storedPath))
    }
}
