//
//  ShellEnvironment.swift
//  SkillsBuddy
//
//  An app opened from Finder gets launchd's bare PATH, which has no node or npx.
//  This asks the user's login shell for its PATH once, so `npx` resolves the
//  same way it does in Terminal (nvm, Herd, Homebrew, …).
//

import Foundation

nonisolated struct ShellEnvironment: Sendable {
    let variables: [String: String]

    var searchPaths: [String] {
        (variables["PATH"] ?? "").split(separator: ":").map(String.init)
    }

    var homeDirectoryURL: URL { FileManager.default.homeDirectoryForCurrentUser }

    func executableURL(named name: String) -> URL? {
        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The process environment with PATH replaced by the login shell's.
    @concurrent static func resolve() async -> ShellEnvironment {
        var variables = ProcessInfo.processInfo.environment
        let fallbackPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let loginPath = await loginShellPath()
        let combined = (loginPath?.split(separator: ":").map(String.init) ?? (variables["PATH"] ?? "").split(separator: ":").map(String.init)) + fallbackPaths
        var seen = Set<String>()
        variables["PATH"] = combined.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        return ShellEnvironment(variables: variables)
    }

    private static let pathMarker = "__SKILLS_BUDDY_PATH__="

    /// Runs the user's shell as an interactive login shell (so `.zprofile` and
    /// `.zshrc` both load) and reads PATH back from a marked line, ignoring
    /// anything the shell's startup files print.
    @concurrent private static func loginShellPath() async -> String? {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let result = try? await CommandRunner.run(
            executableURL: URL(fileURLWithPath: shellPath),
            arguments: ["-l", "-i", "-c", "echo \"\(pathMarker)$PATH\""],
            timeout: .seconds(10)
        ) else { return nil }
        let markedLine = result.standardOutput
            .split(separator: "\n")
            .last { $0.contains(pathMarker) }
        guard let markedLine, let markerRange = markedLine.range(of: pathMarker) else { return nil }
        let path = String(markedLine[markerRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
