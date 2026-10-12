import Foundation
import Synchronization

/// Runs a program with an empty environment and reads its standard output line by line.
struct LineProcess: Sendable {
    static let maxRestarts = 3

    let executable: URL
    let arguments: [String]
    let maxLineLength: Int
    /// Names the program in the log when it exits.
    let name: String

    /// Output lines. Restarts the program after an exit, at most 3 times. Cancelling the
    /// consumer terminates the process.
    func lines() -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                var restarts = 0
                while !Task.isCancelled {
                    let status = await run { continuation.yield($0) }
                    if Task.isCancelled || restarts == Self.maxRestarts { break }
                    restarts += 1
                    Log.adapter.error("\(name, privacy: .public) exited with \(status), restart \(restarts)")
                    try? await Task.sleep(for: .seconds(1 << (restarts - 1)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs the program once and returns its exit status.
    func run(onOutput: (@Sendable (String) -> Void)?) async -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = [:]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = onOutput == nil ? FileHandle.nullDevice : pipe
        if let onOutput {
            let splitter = Mutex(BoundedLineSplitter(maxLength: maxLineLength))
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                for line in splitter.withLock({ $0.feed(data) }) { onOutput(line) }
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Int32, Never>) in
                process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    done.resume(returning: -1)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
