//
//  OffMainThread.swift
//  SkillsBuddy
//
//  The project builds with approachable concurrency, so a plain `nonisolated
//  async` function runs on its caller's actor: called from `SkillLibrary` (the
//  main actor), it would scan folders and move files on the main thread and
//  freeze the UI. Services mark their entry points `@concurrent`, and blocking
//  calls the main actor makes itself go through `runOffMain`.
//

import Foundation

/// Runs blocking work (file moves, trashing) on the concurrent pool, off the main actor.
@concurrent
nonisolated func runOffMain<Result: Sendable>(_ work: @escaping @Sendable () throws -> Result) async throws -> Result {
    warnIfOnMainThread("runOffMain")
    return try work()
}

/// Debug builds print a warning when heavy work lands on the main thread.
nonisolated func warnIfOnMainThread(_ work: StaticString, file: StaticString = #fileID, line: UInt = #line) {
    #if DEBUG
    if Thread.isMainThread {
        print("⚠️ Main-thread work: \(work) at \(file):\(line)")
    }
    #endif
}

/// `transform` applied to every element on the concurrent pool, at most
/// `limit` at a time, with the results in the elements' order. The limit keeps
/// a long list from starting a process per element all at once (each skill
/// can run `git` twice).
@concurrent
nonisolated func concurrentMap<Element: Sendable, Mapped: Sendable>(
    _ elements: [Element],
    limit: Int = ProcessInfo.processInfo.activeProcessorCount,
    _ transform: @escaping @Sendable (Element) async -> Mapped
) async -> [Mapped] {
    await withTaskGroup(of: (Int, Mapped).self, returning: [Mapped].self) { group in
        var results = [Mapped?](repeating: nil, count: elements.count)
        var nextIndex = 0
        func startNext() {
            guard nextIndex < elements.count else { return }
            let index = nextIndex
            let element = elements[index]
            nextIndex += 1
            group.addTask { (index, await transform(element)) }
        }
        for _ in 0..<max(1, limit) { startNext() }
        while let (index, mapped) = await group.next() {
            results[index] = mapped
            startNext()
        }
        return results.compactMap { $0 }
    }
}
