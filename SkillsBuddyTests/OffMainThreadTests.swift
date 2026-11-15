//
//  OffMainThreadTests.swift
//  SkillsBuddyTests
//

import Foundation
import Testing
@testable import Skills_Buddy

@MainActor
struct OffMainThreadTests {
    @Test func runOffMainLeavesTheMainThreadFromTheMainActor() async throws {
        #expect(Thread.isMainThread)
        let ranOnMainThread = try await runOffMain { Thread.isMainThread }
        #expect(!ranOnMainThread)
    }

    @Test func runOffMainPassesErrorsThrough() async {
        struct Failure: Error {}
        await #expect(throws: Failure.self) {
            try await runOffMain { throw Failure() }
        }
    }
}

@MainActor
struct ConcurrentMapTests {
    @Test func keepsTheElementsOrder() async {
        let doubled = await concurrentMap(Array(0..<50), limit: 4) { number in
            try? await Task.sleep(for: .milliseconds(Int.random(in: 0...5)))
            return number * 2
        }
        #expect(doubled == (0..<50).map { $0 * 2 })
    }

    @Test func runsNoMoreThanTheLimitAtOnce() async {
        let gauge = ConcurrencyGauge()
        _ = await concurrentMap(Array(0..<30), limit: 3) { _ in
            await gauge.enter()
            try? await Task.sleep(for: .milliseconds(5))
            await gauge.leave()
        }
        #expect(await gauge.peak <= 3)
        #expect(await gauge.peak > 1)
    }
}

private actor ConcurrencyGauge {
    private var running = 0
    private(set) var peak = 0

    func enter() {
        running += 1
        peak = max(peak, running)
    }

    func leave() { running -= 1 }
}
