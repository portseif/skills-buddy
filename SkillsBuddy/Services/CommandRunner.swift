//
//  CommandRunner.swift
//  SkillsBuddy
//
//  Runs a command line tool off the main actor, streaming its output by line.
//

import Foundation

nonisolated struct CommandOutputLine: Hashable, Sendable {
    let text: String
    let isError: Bool
}

nonisolated struct CommandResult: Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool { exitCode == 0 }

    /// The most useful text to show when the command failed.
    var failureSummary: String {
        let errorText = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputText = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = errorText.isEmpty ? outputText : errorText
        return text.isEmpty ? "Exited with code \(exitCode)." : String(text.suffix(600))
    }
}

nonisolated enum CommandError: LocalizedError {
    case executableNotFound(String)
    case timedOut(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            "Couldn't find `\(name)` on your login shell's PATH."
        case .timedOut(let command):
            "`\(command)` took too long and was stopped."
        case .failed(let summary):
            summary
        }
    }
}

nonisolated enum CommandRunner {
    /// Runs `executableURL` and returns once it exits. Cancelling the calling task
    /// terminates the process.
    @concurrent static func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        standardInput: Data? = nil,
        onOutput: (@Sendable (CommandOutputLine) -> Void)? = nil
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let inputPipe = standardInput.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        if let environment { process.environment = environment }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let collector = OutputCollector(onOutput: onOutput)
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData, isError: false)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData, isError: true)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finishedProcess in
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    collector.append(remainingData(in: outputPipe.fileHandleForReading), isError: false)
                    collector.append(remainingData(in: errorPipe.fileHandleForReading), isError: true)
                    let (standardOutput, standardError) = collector.finish()
                    continuation.resume(returning: CommandResult(
                        exitCode: finishedProcess.terminationStatus,
                        standardOutput: standardOutput,
                        standardError: standardError
                    ))
                }
                do {
                    try process.run()
                    if let inputPipe, let standardInput {
                        inputPipe.fileHandleForWriting.write(standardInput)
                        try? inputPipe.fileHandleForWriting.close()
                    }
                } catch {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            guard process.isRunning else { return }
            process.terminate()
            // An interactive shell (the login shell `ShellEnvironment` reads PATH
            // from) ignores SIGTERM, and the continuation above only resumes
            // once the process exits: kill it if it's still there shortly after.
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    /// What's left in a pipe once its process has exited, without waiting for
    /// end of file: a child the process left running (a shell's background job)
    /// can hold the pipe open long after, and `readDataToEndOfFile` would wait
    /// for it.
    private static func remainingData(in handle: FileHandle) -> Data {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            // 0 is end of file; -1 with EAGAIN means nothing more right now.
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    /// `run`, stopped with `CommandError.timedOut` after `timeout`.
    @concurrent static func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: Duration
    ) async throws -> CommandResult {
        try await withThrowingTaskGroup(of: CommandResult.self) { group in
            group.addTask {
                try await run(executableURL: executableURL, arguments: arguments, workingDirectory: workingDirectory, environment: environment)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CommandError.timedOut(executableURL.lastPathComponent)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CommandError.timedOut(executableURL.lastPathComponent)
            }
            return result
        }
    }

    /// Removes ANSI escape sequences (colors, cursor moves) from CLI output.
    static func stripANSI(_ text: String) -> String {
        text.replacing(/\u{1B}\[[0-9;?]*[ -\/]*[@-~]/, with: "")
    }
}

// MARK: - Output collection

/// Collects both streams and reports complete lines as they arrive. The pipe
/// handlers run on background queues, so all state sits behind a lock.
private nonisolated final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let onOutput: (@Sendable (CommandOutputLine) -> Void)?
    private var outputData = Data()
    private var errorData = Data()
    private var pendingOutputLine = ""
    private var pendingErrorLine = ""

    init(onOutput: (@Sendable (CommandOutputLine) -> Void)?) {
        self.onOutput = onOutput
    }

    func append(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if isError { errorData.append(data) } else { outputData.append(data) }
        guard onOutput != nil else { return }

        let chunk = String(decoding: data, as: UTF8.self)
        var pending = (isError ? pendingErrorLine : pendingOutputLine) + chunk
        while let newlineIndex = pending.firstIndex(of: "\n") {
            emit(String(pending[..<newlineIndex]), isError: isError)
            pending = String(pending[pending.index(after: newlineIndex)...])
        }
        if isError { pendingErrorLine = pending } else { pendingOutputLine = pending }
    }

    func finish() -> (String, String) {
        lock.lock()
        defer { lock.unlock() }
        emit(pendingOutputLine, isError: false)
        emit(pendingErrorLine, isError: true)
        pendingOutputLine = ""
        pendingErrorLine = ""
        return (String(decoding: outputData, as: UTF8.self), String(decoding: errorData, as: UTF8.self))
    }

    /// Spinners redraw a line with `\r`; only the last redraw is worth showing.
    private func emit(_ rawLine: String, isError: Bool) {
        let lastRedraw = rawLine.split(separator: "\r", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let text = CommandRunner.stripANSI(lastRedraw).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        onOutput?(CommandOutputLine(text: text, isError: isError))
    }
}
