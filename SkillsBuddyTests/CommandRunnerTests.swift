//
//  CommandRunnerTests.swift
//  SkillsBuddyTests
//

import Foundation
import Testing
@testable import Skills_Buddy

struct CommandRunnerTests {
    @Test func outputIsCollectedInFull() async throws {
        let result = try await CommandRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'one\\ntwo\\n'; printf 'oops' >&2; exit 3"]
        )
        #expect(result.standardOutput == "one\ntwo\n")
        #expect(result.standardError == "oops")
        #expect(result.exitCode == 3)
    }

    /// Like an interactive login shell: it ignores SIGTERM, and a child it
    /// started still holds its output open after it's gone.
    @Test func timeoutStopsAShellThatIgnoresTermination() async throws {
        let started = ContinuousClock.now
        await #expect(throws: CommandError.self) {
            try await CommandRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; sleep 20"],
                timeout: .seconds(1)
            )
        }
        // One second to time out, then SIGTERM is ignored and SIGKILL follows two seconds later.
        #expect(ContinuousClock.now - started < .seconds(8))
    }
}
