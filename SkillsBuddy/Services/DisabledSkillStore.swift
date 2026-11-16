//
//  DisabledSkillStore.swift
//  SkillsBuddy
//
//  No agent has a "disabled skill" setting, so disabling moves the skill's
//  entry (folder or link) out of the agent's skills folder into
//  ~/Library/Application Support/io.portseif.SkillsBuddy/Disabled, and a
//  manifest remembers where it came from. Enabling moves it back exactly:
//  same files, same version, no network.
//
//  Agents that read the same folder (Codex, Pi, Warp and Zed all read
//  ~/.agents/skills) share one entry, so they're disabled together.
//

import Foundation

/// One entry moved out of an agent's skills folder.
nonisolated struct DisabledSkillEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    /// The folder name, as the agents and the `skills` CLI know it.
    let skillName: String
    /// Where the entry lived, and goes back to.
    let originalPath: String
    /// Where it waits while disabled.
    let storedPath: String
    /// The agents that loaded it from `originalPath`.
    let agentNames: [String]
    let disabledAt: Date

    var originalURL: URL { URL(fileURLWithPath: originalPath) }
    var storedURL: URL { URL(fileURLWithPath: storedPath) }
}

nonisolated enum DisabledSkillError: LocalizedError {
    case originalLocationTaken(String)

    var errorDescription: String? {
        switch self {
        case .originalLocationTaken(let path):
            "Something is already at \(path). Move or remove it, then enable again."
        }
    }
}

nonisolated struct DisabledSkillStore: Sendable {
    let rootURL: URL

    static let standard = DisabledSkillStore(rootURL: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "io.portseif.SkillsBuddy/Disabled", directoryHint: .isDirectory))

    private var manifestURL: URL { rootURL.appendingPathComponent("manifest.json") }

    func entries() -> [DisabledSkillEntry] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        return (try? JSONDecoder.manifest.decode([DisabledSkillEntry].self, from: data)) ?? []
    }

    /// Moves the item at `originalURL` (a symlink moves as a link) into the store.
    @discardableResult
    func disable(itemAt originalURL: URL, skillName: String, agentNames: [String]) throws -> DisabledSkillEntry {
        let id = UUID()
        let holderURL = rootURL.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: holderURL, withIntermediateDirectories: true)
        let storedURL = holderURL.appendingPathComponent(originalURL.lastPathComponent)
        try FileManager.default.moveItem(at: originalURL, to: storedURL)

        let entry = DisabledSkillEntry(
            id: id,
            skillName: skillName,
            originalPath: originalURL.path,
            storedPath: storedURL.path,
            agentNames: agentNames,
            disabledAt: .now
        )
        try save(entries() + [entry])
        return entry
    }

    /// Moves the entry back where it was. Refuses if something new is there.
    func enable(_ entry: DisabledSkillEntry) throws {
        guard !Self.itemExists(at: entry.originalURL) else {
            throw DisabledSkillError.originalLocationTaken(entry.originalPath)
        }
        try FileManager.default.createDirectory(at: entry.originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: entry.storedURL, to: entry.originalURL)
        try? FileManager.default.removeItem(at: entry.storedURL.deletingLastPathComponent())
        try save(entries().filter { $0.id != entry.id })
    }

    /// Sends a disabled entry to the Trash and forgets it.
    func discard(_ entry: DisabledSkillEntry) throws {
        if Self.itemExists(at: entry.storedURL) {
            try FileManager.default.trashItem(at: entry.storedURL, resultingItemURL: nil)
        }
        try? FileManager.default.removeItem(at: entry.storedURL.deletingLastPathComponent())
        try save(entries().filter { $0.id != entry.id })
    }

    /// The disabled skill's own folder, for reading its SKILL.md: a stored
    /// folder, or a stored link resolved from where it used to live.
    func skillFolder(of entry: DisabledSkillEntry) -> URL? {
        let fileManager = FileManager.default
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: entry.storedPath) {
            let target = URL(fileURLWithPath: destination, relativeTo: entry.originalURL.deletingLastPathComponent()).standardizedFileURL
            return fileManager.fileExists(atPath: target.appendingPathComponent("SKILL.md").path) ? target : nil
        }
        return fileManager.fileExists(atPath: entry.storedURL.appendingPathComponent("SKILL.md").path) ? entry.storedURL : nil
    }

    private func save(_ entries: [DisabledSkillEntry]) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try JSONEncoder.manifest.encode(entries).write(to: manifestURL, options: .atomic)
    }

    /// True for a broken symlink too.
    static func itemExists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}

private extension JSONDecoder {
    nonisolated static var manifest: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    nonisolated static var manifest: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
