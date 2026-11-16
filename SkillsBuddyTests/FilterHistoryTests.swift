//
//  FilterHistoryTests.swift
//  SkillsBuddyTests
//

import Testing
@testable import Skills_Buddy

struct FilterHistoryTests {
    @Test func backAndForwardRetraceVisits() {
        var history = FilterHistory()
        #expect(!history.canGoBack && !history.canGoForward)

        // all → Antigravity → Disabled
        history.recordVisit(leaving: .all)
        history.recordVisit(leaving: .agent("Antigravity"))

        #expect(history.goBack(from: .disabled) == .agent("Antigravity"))
        #expect(history.goBack(from: .agent("Antigravity")) == .all)
        #expect(!history.canGoBack)
        #expect(history.goForward(from: .all) == .agent("Antigravity"))
        #expect(history.goForward(from: .agent("Antigravity")) == .disabled)
        #expect(!history.canGoForward)
    }

    @Test func aNewVisitClearsTheWayForward() {
        var history = FilterHistory()
        history.recordVisit(leaving: .all)
        _ = history.goBack(from: .disabled)
        #expect(history.canGoForward)

        history.recordVisit(leaving: .all)
        #expect(!history.canGoForward)
        #expect(history.canGoBack)
    }

    @Test func backKeepsOnlyTheMostRecentVisits() {
        var history = FilterHistory()
        for index in 0..<(FilterHistory.maximumDepth + 25) {
            history.recordVisit(leaving: .agent("Agent \(index)"))
        }
        #expect(history.backStack.count == FilterHistory.maximumDepth)
        // The newest visit is on top; the oldest 25 dropped off.
        #expect(history.backStack.last == .agent("Agent \(FilterHistory.maximumDepth + 24)"))
        #expect(history.backStack.first == .agent("Agent 25"))
    }
}
