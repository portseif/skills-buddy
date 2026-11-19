//
//  RepoFinder.swift
//  SkillsBuddy
//
//  Looks for the repositories of skills that have none, a few at a time:
//  GitHub searches are spaced to its limit, while reading files and asking
//  Apple Intelligence overlap with the waits. Results stay while the app runs.
//

import Foundation
import Observation

@Observable
final class RepoFinder {
    nonisolated enum Status: Equatable, Sendable {
        case waiting
        case searching
        case found(RepoMatch)
        case notFound
        case failed(String)
    }

    private(set) var statuses: [Skill.ID: Status] = [:]
    private(set) var isRunning = false
    /// Set when the search can't start at all (no `gh`, or signed out).
    private(set) var setupError: String?
    /// Read when a search starts; Apple Intelligence can be turned on or off meanwhile.
    private(set) var intelligence = IntelligenceStatus.forFindingRepositories

    @ObservationIgnored private var scanTask: Task<Void, Never>?

    /// Skills searched at once. Their GitHub searches still go one at a time.
    private static let concurrentSkills = 3

    /// Skills a repository can be found for: installed for an agent, with no source.
    static func isEligible(_ skill: Skill) -> Bool {
        skill.sourceKind == .local && skill.repository == nil && !skill.agents.isEmpty
    }

    func status(of skillID: Skill.ID) -> Status? { statuses[skillID] }

    /// Searches for each skill's repository, skipping ones already found.
    func search(_ skills: [Skill], environment: ShellEnvironment) {
        guard !isRunning else { return }
        let pending = skills.filter { skill in
            if case .found = statuses[skill.id] { return false }
            return true
        }
        guard !pending.isEmpty else { return }
        intelligence = IntelligenceStatus.forFindingRepositories
        setupError = nil
        statuses.merge(pending.map { ($0.id, .waiting) }) { _, waiting in waiting }
        isRunning = true

        let search = GitHubSkillSearch(environment: environment)
        let matcher = SkillRepoMatcher(search: search, pacer: SearchPacer(), advisor: intelligence.advisor)
        scanTask = Task {
            defer { isRunning = false }
            do {
                try await search.ensureReady()
            } catch {
                setupError = error.localizedDescription
                statuses.merge(pending.map { ($0.id, .failed(error.localizedDescription)) }) { _, failed in failed }
                return
            }
            await withTaskGroup(of: (Skill.ID, Status).self) { group in
                var queue = pending[...]
                func startNext() {
                    guard let skill = queue.popFirst() else { return }
                    statuses[skill.id] = .searching
                    group.addTask { (skill.id, await Self.find(skill, with: matcher)) }
                }
                for _ in 0..<Self.concurrentSkills { startNext() }
                while let (skillID, status) = await group.next() {
                    statuses[skillID] = status
                    if !Task.isCancelled { startNext() }
                }
            }
            // Stopped part way: the rest go back to waiting.
            for skill in pending where statuses[skill.id] == .searching || statuses[skill.id] == .waiting {
                statuses[skill.id] = nil
            }
        }
    }

    func stop() {
        scanTask?.cancel()
    }

    @concurrent private nonisolated static func find(_ skill: Skill, with matcher: SkillRepoMatcher) async -> Status {
        guard let profile = LocalSkillProfile.load(for: skill) else { return .failed("Couldn't read its SKILL.md.") }
        do {
            return try await matcher.match(for: profile).map(Status.found) ?? .notFound
        } catch is CancellationError {
            return .waiting
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
