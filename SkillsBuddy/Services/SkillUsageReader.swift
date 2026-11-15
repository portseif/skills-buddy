//
//  SkillUsageReader.swift
//  SkillsBuddy
//
//  When each skill was last used, from Claude Code's session transcripts
//  (~/.claude/projects/**/*.jsonl, subagents' included). A `Skill` tool call
//  names the skill it loads and a slash command (`/humanizer`) names the one
//  it runs; every transcript line carries a timestamp. Plugin skills appear
//  as `plugin:skill` (`figma:figma-use`).
//
//  Transcripts run to gigabytes, so each file's result is cached with how far
//  it was read. They only grow, so a later read covers just the new lines.
//

import Darwin
import Foundation

nonisolated struct SkillUsageReader: Sendable {
    /// `~/.claude/projects`.
    let transcriptsDirectoryURL: URL
    /// Where each file's last uses and read position are kept between launches.
    let cacheFileURL: URL

    init(homeDirectoryURL: URL, cacheFileURL: URL = Self.defaultCacheFileURL) {
        self.transcriptsDirectoryURL = homeDirectoryURL.appending(path: ".claude/projects", directoryHint: .isDirectory)
        self.cacheFileURL = cacheFileURL
    }

    /// `~/Library/Caches/io.portseif.SkillsBuddy/SkillUsage.json`.
    static var defaultCacheFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "io.portseif.SkillsBuddy/SkillUsage.json")
    }

    /// The last use of every skill seen, keyed as Claude Code names it
    /// (`humanizer`, `figma:figma-use`).
    @concurrent func lastUseDates() async -> [String: Date] {
        warnIfOnMainThread("SkillUsageReader.lastUseDates")
        var cache = loadCache()
        var seenPaths = Set<String>()
        var pending: [(fileURL: URL, entry: SkillUsageCache.FileEntry)] = []

        for fileURL in transcriptFileURLs() {
            guard let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { continue }
            seenPaths.insert(fileURL.path)
            var entry = cache.files[fileURL.path] ?? SkillUsageCache.FileEntry()
            // Rewritten rather than appended to: read it again from the start.
            if size < entry.readLength { entry = SkillUsageCache.FileEntry() }
            if size > entry.readLength { pending.append((fileURL, entry)) }
        }

        // Transcripts are independent: scan them side by side (the first read
        // covers every one).
        let scanned = await concurrentMap(pending) { file -> (path: String, entry: SkillUsageCache.FileEntry)? in
            guard let (lastUses, readLength) = Self.scan(file.fileURL, from: file.entry.readLength) else { return nil }
            var entry = file.entry
            entry.readLength = readLength
            entry.lastUses.merge(lastUses) { max($0, $1) }
            return (file.fileURL.path, entry)
        }
        for case let (path, entry)? in scanned { cache.files[path] = entry }

        cache.files = cache.files.filter { seenPaths.contains($0.key) }
        saveCache(cache)
        return cache.files.values.reduce(into: [:]) { result, entry in
            result.merge(entry.lastUses) { max($0, $1) }
        }
    }

    // MARK: - Files

    private func transcriptFileURLs() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: transcriptsDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    private func loadCache() -> SkillUsageCache {
        guard let data = try? Data(contentsOf: cacheFileURL),
              let cache = try? JSONDecoder().decode(SkillUsageCache.self, from: data),
              cache.version == SkillUsageCache.currentVersion
        else { return SkillUsageCache() }
        return cache
    }

    private func saveCache(_ cache: SkillUsageCache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheFileURL, options: .atomic)
    }

    // MARK: - Scanning

    private static let toolCallNeedle = Array(#""name":"Skill""#.utf8)
    private static let slashCommandNeedle = Array("<command-name>/".utf8)

    /// The skills used in the file's complete lines from `offset` on, and the
    /// offset just past the last complete line (a line still being written is
    /// left for next time). Only lines holding a needle are parsed.
    static func scan(_ fileURL: URL, from offset: Int) -> (lastUses: [String: Date], readLength: Int)? {
        guard let data = try? Data(contentsOf: fileURL, options: .alwaysMapped) else { return nil }
        return data.withUnsafeBytes { buffer -> (lastUses: [String: Date], readLength: Int)? in
            guard let base = buffer.baseAddress, buffer.count > offset else { return nil }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            // Stop at the last newline: anything after it may be half-written.
            var end = buffer.count
            while end > offset, bytes[end - 1] != UInt8(ascii: "\n") { end -= 1 }
            guard end > offset else { return ([:], offset) }

            var lineStarts = Set<Int>()
            for needle in [toolCallNeedle, slashCommandNeedle] {
                var position = offset
                while position < end,
                      let match = memmem(bytes + position, end - position, needle, needle.count) {
                    let matchIndex = bytes.distance(to: match.assumingMemoryBound(to: UInt8.self))
                    var lineStart = matchIndex
                    while lineStart > offset, bytes[lineStart - 1] != UInt8(ascii: "\n") { lineStart -= 1 }
                    lineStarts.insert(lineStart)
                    position = matchIndex + needle.count
                }
            }

            var lastUses: [String: Date] = [:]
            let dateParser = ISO8601DateFormatter()
            dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for lineStart in lineStarts {
                var lineEnd = lineStart
                while lineEnd < end, bytes[lineEnd] != UInt8(ascii: "\n") { lineEnd += 1 }
                let line = Data(bytes: bytes + lineStart, count: lineEnd - lineStart)
                for (name, date) in usages(inLine: line, dateParser: dateParser) {
                    lastUses[name] = max(lastUses[name] ?? .distantPast, date)
                }
            }
            return (lastUses, end)
        }
    }

    /// The skills one transcript line uses: an assistant line's `Skill` tool
    /// calls, or a user line that's a slash command. Tool results quoting
    /// either (a grep of a transcript, say) are neither, so they don't count.
    static func usages(inLine line: Data, dateParser: ISO8601DateFormatter) -> [(name: String, date: Date)] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let timestamp = object["timestamp"] as? String,
              let date = dateParser.date(from: timestamp),
              let message = object["message"] as? [String: Any]
        else { return [] }

        switch object["type"] as? String {
        case "assistant":
            let content = message["content"] as? [[String: Any]] ?? []
            return content.compactMap { item in
                guard item["type"] as? String == "tool_use", item["name"] as? String == "Skill",
                      let input = item["input"] as? [String: Any], let skill = input["skill"] as? String
                else { return nil }
                return (normalizedName(skill), date)
            }
        case "user":
            // A slash command is the whole message, as a string; a tool result is an array.
            guard let text = message["content"] as? String,
                  let match = text.firstMatch(of: /<command-name>\/([^<\s]+)<\/command-name>/)
            else { return [] }
            return [(normalizedName(String(match.output.1)), date)]
        default:
            return []
        }
    }

    private static func normalizedName(_ name: String) -> String {
        name.hasPrefix("/") ? String(name.dropFirst()) : name
    }
}

/// Each transcript's last skill uses and how far it's been read.
nonisolated struct SkillUsageCache: Codable, Sendable {
    static let currentVersion = 1

    struct FileEntry: Codable, Sendable {
        var readLength = 0
        var lastUses: [String: Date] = [:]
    }

    var version = Self.currentVersion
    var files: [String: FileEntry] = [:]
}
