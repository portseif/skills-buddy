//
//  FilterHistory.swift
//  SkillsBuddy
//
//  Back and forward through the sidebar filters, like a browser: picking a
//  filter records where you were and clears the way forward.
//

import Foundation

struct FilterHistory: Equatable {
    private(set) var backStack: [LibraryFilter] = []
    private(set) var forwardStack: [LibraryFilter] = []

    /// How far Back reaches; older filters drop off so the stack can't grow
    /// for as long as the window is open.
    static let maximumDepth = 50

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// A filter picked directly (not by Back or Forward).
    mutating func recordVisit(leaving previous: LibraryFilter) {
        backStack.append(previous)
        if backStack.count > Self.maximumDepth {
            backStack.removeFirst(backStack.count - Self.maximumDepth)
        }
        forwardStack.removeAll()
    }

    mutating func goBack(from current: LibraryFilter) -> LibraryFilter? {
        guard let target = backStack.popLast() else { return nil }
        forwardStack.append(current)
        return target
    }

    mutating func goForward(from current: LibraryFilter) -> LibraryFilter? {
        guard let target = forwardStack.popLast() else { return nil }
        backStack.append(current)
        return target
    }
}
