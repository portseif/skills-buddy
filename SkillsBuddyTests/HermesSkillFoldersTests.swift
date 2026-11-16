//
//  HermesSkillFoldersTests.swift
//  SkillsBuddyTests
//

import Foundation
import Testing
@testable import Skills_Buddy

struct HermesSkillFoldersTests {
    /// Resolved up front (`/var` is a link to `/private/var`) so paths compare as written.
    private let rootURL = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appending(path: "HermesSkillFoldersTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func makeSkillFolder(_ relativePath: String, in baseURL: URL) throws {
        let folderURL = baseURL.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try "---\nname: \(folderURL.lastPathComponent)\ndescription: Sample.\n---\n".write(to: folderURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    @Test func walkFollowsHermesRules() throws {
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let skillsURL = rootURL.appending(path: "skills", directoryHint: .isDirectory)
        for relativePath in [
            "top",
            "top/sub",                               // Hermes looks inside a skill too
            "top/references/inner",                  // a skill's support folder
            "creative/humanizer",
            "software-development/tools/linter",
            "category/scripts/real",                 // `scripts` only counts inside a skill
            ".hub/quarantine/bad",
            "creative/node_modules/package",
        ] {
            try makeSkillFolder(relativePath, in: skillsURL)
        }
        let elsewhereURL = rootURL.appending(path: "elsewhere", directoryHint: .isDirectory)
        try makeSkillFolder("thing", in: elsewhereURL)
        try FileManager.default.createSymbolicLink(at: skillsURL.appending(path: "linked"), withDestinationURL: elsewhereURL)
        try FileManager.default.createSymbolicLink(at: skillsURL.appending(path: "creative/loop"), withDestinationURL: skillsURL)

        let relativePaths = SkillScanner.hermesSkillFolders(in: skillsURL).map { String($0.path.dropFirst(skillsURL.path.count + 1)) }
        #expect(relativePaths == [
            "category/scripts/real",
            "creative/humanizer",
            "linked/thing",
            "software-development/tools/linter",
            "top",
            "top/sub",
        ])
    }

    @Test func scanNamesSymlinkedAndInnerSkillsByTheirPath() async throws {
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let home = rootURL.appending(path: "home", directoryHint: .isDirectory)
        let hermes = home.appending(path: ".hermes/skills", directoryHint: .isDirectory)
        try makeSkillFolder("devops/parent", in: hermes)
        try makeSkillFolder("devops/parent/child", in: hermes)
        let elsewhereURL = rootURL.appending(path: "elsewhere", directoryHint: .isDirectory)
        try makeSkillFolder("thing", in: elsewhereURL)
        try FileManager.default.createSymbolicLink(at: hermes.appending(path: "linked"), withDestinationURL: elsewhereURL)

        let environment = ShellEnvironment(variables: ["PATH": ""])
        let scanner = SkillScanner(
            homeDirectoryURL: home,
            git: GitClient(environment: environment),
            cli: SkillsCLI(environment: environment),
            disabledStore: DisabledSkillStore(rootURL: rootURL.appending(path: "Disabled", directoryHint: .isDirectory))
        )
        let result = await scanner.scan()

        #expect(result.skills.map(\.id).sorted() == ["skill:devops/parent", "skill:devops/parent/child", "skill:linked/thing"])
        let linked = try #require(result.skills.first { $0.id == "skill:linked/thing" })
        #expect(linked.agents.map(\.displayName) == ["Hermes Agent"])
        #expect(linked.agents.first?.folderURL?.path == hermes.appending(path: "linked/thing").path)
    }
}
