//
//  SkillUsageReaderTests.swift
//  SkillsBuddyTests
//

import Foundation
import Testing
@testable import Skills_Buddy

struct SkillUsageReaderTests {
    private let homeURL = FileManager.default.temporaryDirectory.appending(path: "SkillUsageReaderTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private var reader: SkillUsageReader {
        SkillUsageReader(homeDirectoryURL: homeURL, cacheFileURL: homeURL.appending(path: "cache/SkillUsage.json"))
    }

    private var transcriptURL: URL {
        homeURL.appending(path: ".claude/projects/-Users-me-project/session.jsonl")
    }

    private func date(_ text: String) -> Date {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: text)!
    }

    private func toolCallLine(_ skill: String, at timestamp: String) -> String {
        #"{"type":"assistant","timestamp":"\#(timestamp)","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"\#(skill)"}}]}}"#
    }

    private func slashCommandLine(_ command: String, at timestamp: String) -> String {
        #"{"type":"user","timestamp":"\#(timestamp)","message":{"role":"user","content":"<command-message>x</command-message>\n<command-name>/\#(command)</command-name>"}}"#
    }

    /// A tool result that quotes a slash command, like a grep of a transcript.
    private func quotedCommandLine(at timestamp: String) -> String {
        #"{"type":"user","timestamp":"\#(timestamp)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"<command-name>/quoted</command-name>"}]}}"#
    }

    private func write(_ lines: [String], appending: Bool = false, trailingNewline: Bool = true) throws {
        try FileManager.default.createDirectory(at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        if appending, let handle = try? FileHandle(forWritingTo: transcriptURL) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try text.write(to: transcriptURL, atomically: true, encoding: .utf8)
        }
    }

    @Test func readsToolCallsAndSlashCommandsButNotQuotes() async throws {
        defer { try? FileManager.default.removeItem(at: homeURL) }
        try write([
            toolCallLine("humanizer", at: "2026-06-10T21:03:10.892Z"),
            slashCommandLine("figma:figma-use", at: "2026-06-11T09:00:00.000Z"),
            quotedCommandLine(at: "2026-06-12T09:00:00.000Z"),
            toolCallLine("humanizer", at: "2026-06-09T08:00:00.000Z"),
        ])

        let lastUses = await reader.lastUseDates()
        #expect(lastUses["humanizer"] == date("2026-06-10T21:03:10.892Z"))
        #expect(lastUses["figma:figma-use"] == date("2026-06-11T09:00:00.000Z"))
        #expect(lastUses["quoted"] == nil)
    }

    @Test func appendedLinesAreReadOnTheNextPass() async throws {
        defer { try? FileManager.default.removeItem(at: homeURL) }
        try write([toolCallLine("humanizer", at: "2026-06-10T21:03:10.892Z")])
        _ = await reader.lastUseDates()

        // A line still being written isn't read until it ends.
        try write([toolCallLine("humanizer", at: "2026-07-01T10:00:00.000Z")], appending: true, trailingNewline: false)
        #expect(await reader.lastUseDates()["humanizer"] == date("2026-06-10T21:03:10.892Z"))

        try write([""], appending: true)
        #expect(await reader.lastUseDates()["humanizer"] == date("2026-07-01T10:00:00.000Z"))
    }

    @Test func aDeletedTranscriptDropsOutOfTheCache() async throws {
        defer { try? FileManager.default.removeItem(at: homeURL) }
        try write([toolCallLine("humanizer", at: "2026-06-10T21:03:10.892Z")])
        #expect(await reader.lastUseDates()["humanizer"] != nil)

        try FileManager.default.removeItem(at: transcriptURL)
        #expect(await reader.lastUseDates()["humanizer"] == nil)
    }
}
