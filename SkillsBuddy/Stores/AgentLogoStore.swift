//
//  AgentLogoStore.swift
//  SkillsBuddy
//
//  Agent logos: each agent's homepage icon from Google's favicon service
//  (consistent 64×64 PNGs), fetched once and kept in
//  ~/Library/Caches/io.portseif.SkillsBuddy/AgentLogos. Only the agent's
//  domain is sent. Agents without a known homepage, or whose icon can't be
//  fetched, fall back to the avatar's initials. Each logo also has a
//  one-color mark (`LogoMark`) for the sidebar.
//

import AppKit
import Observation
import SwiftUI

@Observable
final class AgentLogoStore {
    static let shared = AgentLogoStore()

    /// Loaded logos by agent key.
    private var logos: [String: NSImage] = [:]
    /// Their one-color marks, for logos that have a clear one.
    private var marks: [String: NSImage] = [:]
    /// Keys already fetched or being fetched, so a redraw doesn't fetch again.
    @ObservationIgnored private var requestedKeys: Set<String> = []

    /// The agent's logo, or nil while it loads (the view redraws when it lands)
    /// and for agents without one.
    func logo(forAgentNamed displayName: String) -> Image? {
        guard let agent = AgentRegistry.definition(displayName: displayName), let homepage = agent.homepage else { return nil }
        if let logo = logos[agent.key] { return Image(nsImage: logo) }
        load(agentKey: agent.key, homepage: homepage)
        return nil
    }

    /// The agent's logo as a one-color template image, or nil while it loads
    /// and for agents without a logo or a clear mark in it.
    func mark(forAgentNamed displayName: String) -> Image? {
        guard let agent = AgentRegistry.definition(displayName: displayName), let homepage = agent.homepage else { return nil }
        if let mark = marks[agent.key] { return Image(nsImage: mark) }
        load(agentKey: agent.key, homepage: homepage)
        return nil
    }

    private func load(agentKey: String, homepage: String) {
        guard requestedKeys.insert(agentKey).inserted else { return }
        Task {
            guard let loaded = await Self.logoAndMark(agentKey: agentKey, homepage: homepage),
                  let image = NSImage(data: loaded.logo) else { return }
            logos[agentKey] = image
            if let markData = loaded.mark, let mark = NSImage(data: markData) {
                mark.isTemplate = true
                marks[agentKey] = mark
            }
        }
    }

    @concurrent private nonisolated static func logoAndMark(agentKey: String, homepage: String) async -> (logo: Data, mark: Data?)? {
        guard let logo = await logoData(agentKey: agentKey, homepage: homepage) else { return nil }
        return (logo, LogoMark.markPNG(fromLogo: logo))
    }

    private nonisolated static var cacheDirectoryURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "io.portseif.SkillsBuddy/AgentLogos", directoryHint: .isDirectory)
    }

    @concurrent private nonisolated static func logoData(agentKey: String, homepage: String) async -> Data? {
        warnIfOnMainThread("AgentLogoStore.logoData")
        let cacheURL = cacheDirectoryURL.appending(path: "\(agentKey).png")
        if let cached = try? Data(contentsOf: cacheURL) { return cached }

        var components = URLComponents(string: "https://www.google.com/s2/favicons")
        components?.queryItems = [URLQueryItem(name: "domain", value: homepage), URLQueryItem(name: "sz", value: "64")]
        guard let url = components?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        try? FileManager.default.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
        return data
    }
}
