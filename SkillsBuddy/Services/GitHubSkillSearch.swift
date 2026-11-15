//
//  GitHubSkillSearch.swift
//  SkillsBuddy
//
//  Finds copies of a skill on GitHub through the GitHub CLI (`gh`), signed in
//  as the user: a code search for SKILL.md files by name, a repository's star
//  count, and one file's text. GitHub allows 10 code searches a minute;
//  `SearchPacer` keeps to that.
//

import CryptoKit
import Foundation

/// A SKILL.md on GitHub that might be the original of a local skill.
nonisolated struct RepoCandidate: Hashable, Sendable, Identifiable {
    /// `owner/repo`.
    let repository: String
    /// The SKILL.md's path in the repository.
    let path: String
    /// git's id for the file's contents: equal to a local file's
    /// `GitBlobHash` exactly when the two files are the same.
    let blobSHA: String
    let isFork: Bool

    var id: String { "\(repository)/\(path)" }

    /// The skill's folder name in the repository ("" for a SKILL.md at its root).
    var folderName: String {
        ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }

    /// How many folders deep the SKILL.md sits. A skill at `skills/name` is
    /// more likely the original than a copy bundled deep in a collection.
    var depth: Int { path.split(separator: "/").count }

    var webURL: URL? { URL(string: "https://github.com/\(repository)/blob/HEAD/\(path)") }
}

nonisolated enum GitHubSearchError: LocalizedError, Equatable {
    case cliMissing
    case notSignedIn
    case rateLimited
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cliMissing: "The GitHub CLI isn't installed. Install it with `brew install gh`, then sign in with `gh auth login`."
        case .notSignedIn: "The GitHub CLI isn't signed in. Run `gh auth login` in Terminal, then try again."
        case .rateLimited: "GitHub's search limit was reached. Try again in a minute."
        case .failed(let message): message
        }
    }
}

nonisolated struct GitHubSkillSearch: Sendable {
    let environment: ShellEnvironment

    /// Throws when `gh` is missing or signed out, so a scan can say so once
    /// instead of failing for every skill.
    @concurrent func ensureReady() async throws {
        guard environment.executableURL(named: "gh") != nil else { throw GitHubSearchError.cliMissing }
        let result = try await gh(["auth", "status"])
        guard result.succeeded else { throw GitHubSearchError.notSignedIn }
    }

    /// SKILL.md files on GitHub that mention `term`, the newest index first.
    @concurrent func search(_ term: String, limit: Int = 30) async throws -> [RepoCandidate] {
        // Flags first, then `--`, so a term starting with a hyphen isn't read as a flag.
        let result = try await gh(["search", "code", "--filename", "SKILL.md", "--json", "repository,path,sha", "--limit", String(limit), "--", term])
        guard result.succeeded else {
            let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.localizedCaseInsensitiveContains("rate limit") { throw GitHubSearchError.rateLimited }
            throw GitHubSearchError.failed(message.isEmpty ? "GitHub search failed." : message)
        }
        return try Self.decodeSearchResults(Data(result.standardOutput.utf8))
    }

    /// The repository's star count, or nil when it can't be read.
    @concurrent func stars(of repository: String) async -> Int? {
        guard let result = try? await gh(["api", "repos/\(repository)", "--jq", ".stargazers_count"]), result.succeeded else { return nil }
        return Int(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A file's text from the repository's default branch.
    @concurrent func fileText(repository: String, path: String) async -> String? {
        let encodedPath = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        guard let result = try? await gh(["api", "-H", "Accept: application/vnd.github.raw", "repos/\(repository)/contents/\(encodedPath)"]),
              result.succeeded else { return nil }
        return result.standardOutput
    }

    static func decodeSearchResults(_ data: Data) throws -> [RepoCandidate] {
        struct Result: Decodable {
            struct Repository: Decodable {
                let nameWithOwner: String
                let isFork: Bool?
            }
            let path: String
            let sha: String
            let repository: Repository
        }
        return try JSONDecoder().decode([Result].self, from: data).map {
            RepoCandidate(repository: $0.repository.nameWithOwner, path: $0.path, blobSHA: $0.sha, isFork: $0.repository.isFork ?? false)
        }
    }

    private func gh(_ arguments: [String]) async throws -> CommandResult {
        guard let executableURL = environment.executableURL(named: "gh") else { throw GitHubSearchError.cliMissing }
        return try await CommandRunner.run(executableURL: executableURL, arguments: arguments, environment: environment.variables, timeout: .seconds(30))
    }
}

/// git's object id for a file's contents (`git hash-object`): SHA-1 of
/// `blob <byte count>\0` followed by the bytes. It matches the `sha` GitHub
/// search reports, so an identical copy is found without downloading it.
nonisolated enum GitBlobHash {
    static func sha(of data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Spaces GitHub code searches to stay under its limit of 10 a minute, across
/// every skill being searched at once.
actor SearchPacer {
    private let interval: Duration
    private var nextSlot = ContinuousClock.now

    init(interval: Duration = .milliseconds(6_500)) {
        self.interval = interval
    }

    /// Waits for the next free slot. The slot is taken before sleeping, so
    /// callers waiting together line up instead of all going at once.
    func waitTurn() async throws {
        let slot = max(ContinuousClock.now, nextSlot)
        nextSlot = slot + interval
        try await Task.sleep(until: slot, clock: .continuous)
    }
}
