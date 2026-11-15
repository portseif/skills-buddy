//
//  AppleIntelligenceAdvisor.swift
//  SkillsBuddy
//
//  The repo finder's judgment calls, made by Apple's on-device language model
//  (Foundation Models, macOS 26): search phrases for a skill whose name finds
//  nothing, and whether a candidate's description is the same skill. Nothing
//  leaves the Mac. On older systems, or with Apple Intelligence off, the finder
//  matches identical files and close names only.
//

import Foundation
import FoundationModels

/// Whether Apple Intelligence can help, and why not when it can't.
nonisolated enum IntelligenceStatus: Equatable, Sendable {
    case available
    case unavailable(String)

    static var current: IntelligenceStatus {
        guard #available(macOS 26.0, *) else {
            return .unavailable("Apple Intelligence needs macOS 26 or later.")
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Apple Intelligence is off. Turn it on in System Settings to compare descriptions too.")
        case .unavailable(.deviceNotEligible):
            return .unavailable("This Mac can't run Apple Intelligence.")
        case .unavailable(.modelNotReady):
            return .unavailable("Apple Intelligence is still getting ready. Try again later.")
        case .unavailable:
            return .unavailable("Apple Intelligence isn't available right now.")
        }
    }

    /// The advisor to use, when there is one.
    var advisor: (any RepoMatchAdvising)? {
        guard self == .available, #available(macOS 26.0, *) else { return nil }
        return AppleIntelligenceAdvisor()
    }
}

@available(macOS 26.0, *)
nonisolated struct AppleIntelligenceAdvisor: RepoMatchAdvising {
    /// The on-device model's context is small: keep each description short.
    private static let descriptionLimit = 400

    func searchPhrases(for profile: LocalSkillProfile) async -> [String] {
        let session = LanguageModelSession(instructions: """
            You help find where an AI agent skill was published on GitHub. \
            Given a skill's name and description, suggest short phrases that \
            are likely to appear word for word in its SKILL.md file.
            """)
        let prompt = """
            Skill name: \(profile.displayName)
            Description: \(String(profile.summary.prefix(Self.descriptionLimit)))
            """
        guard let response = try? await session.respond(to: prompt, generating: SkillSearchPhrases.self) else { return [] }
        return response.content.phrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\""))) }
            .filter { !$0.isEmpty }
    }

    func sameSkill(as profile: LocalSkillProfile, candidate: CandidateSummary) async -> String? {
        let session = LanguageModelSession(instructions: """
            You compare two AI agent skills that share a name. Decide whether \
            they are the same skill: the same purpose and instructions, possibly \
            a different version. Skills that only share a name or a topic are \
            different skills.
            """)
        let prompt = """
            Skill A: \(profile.displayName): \(String(profile.summary.prefix(Self.descriptionLimit)))

            Skill B: \(candidate.name): \(String(candidate.description.prefix(Self.descriptionLimit)))
            """
        // Greedy: the same pair always gets the same verdict.
        guard let verdict = try? await session.respond(to: prompt, generating: SkillMatchVerdict.self, options: GenerationOptions(samplingMode: .greedy)).content,
              verdict.isSameSkill else { return nil }
        return verdict.comparison
    }
}

@available(macOS 26.0, *)
@Generable(description: "Phrases to search GitHub with for a skill's SKILL.md")
nonisolated struct SkillSearchPhrases {
    @Guide(description: "Up to three distinctive phrases of two to five words, likely to appear word for word in the skill's SKILL.md", .maximumCount(3))
    var phrases: [String]
}

/// The comparison comes first: the model generates properties in the order
/// they're declared, so it reasons before it decides.
@available(macOS 26.0, *)
@Generable(description: "Whether two skills are the same skill")
nonisolated struct SkillMatchVerdict {
    @Guide(description: "One sentence on what each skill is for and how they differ, if at all")
    var comparison: String
    @Guide(description: "True only when both have the same purpose; false when they only share a name or a topic")
    var isSameSkill: Bool
}
