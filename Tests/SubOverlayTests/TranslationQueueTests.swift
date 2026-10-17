import Foundation
@testable import SubOverlayCore
import Synchronization
import Testing
@testable import SubOverlay

/// A translate step that waits for `open()`, then reports one chunk and returns the timing cues.
@MainActor
final class GatedTranslate {
    let started = Mutex<[String]>([])
    private let gates = Mutex<[String: Bool]>([:])
    private let failing = Mutex<Set<String>>([])

    func open(_ target: String) { gates.withLock { $0[target] = true } }
    func fail(_ target: String) { failing.withLock { $0.insert(target) } }

    var translate: TranslationQueue.Translate {
        { [self] job, progress, chunk in
            started.withLock { $0.append(job.targetLanguage) }
            while !gates.withLock({ $0[job.targetLanguage] ?? false }) { try await Task.sleep(for: .milliseconds(2)) }
            if failing.withLock({ $0.contains(job.targetLanguage) }) { throw AppError("Quota exceeded") }
            progress(0.5)
            chunk(job.timing)
            return job.timing
        }
    }
}

final class Recorder: Sendable {
    private let list = Mutex<[String]>([])
    func add(_ event: String) { list.withLock { $0.append(event) } }
    var all: [String] { list.withLock { $0 } }
}

@MainActor
struct TranslationQueueTests {
    let gate = GatedTranslate()
    let events = Recorder()

    func job(_ target: String, key: String? = nil) -> TranslationQueue.Job {
        let cues = [Cue(id: 1, start: 0, end: 1, text: target)]
        return TranslationQueue.Job(key: key ?? "t|\(target)", title: "Pilot", target: target,
                                    make: { TranslationJob(source: cues, sourceLanguage: "en", targetLanguage: target) },
                                    chunk: { _ in events.add("chunk \(target)") },
                                    done: { result in
                                        switch result {
                                        case .success(let cues): events.add("done \(target) \(cues.count)")
                                        case .failure(let error): events.add("failed \(target) \(error.localizedDescription)")
                                        }
                                    })
    }

    /// Waits up to 2 s for `condition`.
    func until(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 where !condition() { try await Task.sleep(for: .milliseconds(2)) }
        #expect(condition())
    }

    // Breaks if two jobs run at once, out of order, or a finished job does not start the next.
    @Test func runsInOrderOneAtATime() async throws {
        let queue = TranslationQueue(translate: gate.translate)
        #expect(queue.enqueue(job("fa")))
        #expect(queue.enqueue(job("ku")))
        try await until { gate.started.withLock { $0 } == ["fa"] }
        #expect(queue.running?.target == "fa")
        #expect(queue.queued.map(\.target) == ["ku"])
        gate.open("fa")
        try await until { events.all.count == 2 }
        #expect(events.all == ["chunk fa", "done fa 1"])
        try await until { gate.started.withLock { $0 } == ["fa", "ku"] }
        gate.open("ku")
        try await until { queue.running == nil }
        #expect(queue.queued.isEmpty)
    }

    // Breaks if the same key is queued twice while it runs or waits.
    @Test func sameKeyIsOneJob() async throws {
        let queue = TranslationQueue(translate: gate.translate)
        #expect(queue.enqueue(job("fa")))
        #expect(!queue.enqueue(job("fa")))
        #expect(queue.enqueue(job("ku")))
        #expect(!queue.enqueue(job("ku")))
        #expect(queue.queued.count == 1)
    }

    // Breaks if cancelling the running job does not start the next, a late chunk of the cancelled
    // job reaches its owner, or the same key cannot run again after a cancel.
    @Test func cancelStartsTheNextAndDropsLateCallbacks() async throws {
        let queue = TranslationQueue(translate: gate.translate)
        _ = queue.enqueue(job("fa"))
        _ = queue.enqueue(job("ku"))
        try await until { gate.started.withLock { $0 } == ["fa"] }
        queue.cancel(key: "t|fa")
        gate.open("fa")
        gate.open("ku")
        try await until { events.all.count == 2 }
        #expect(events.all == ["chunk ku", "done ku 1"])
        #expect(queue.enqueue(job("fa")))
        try await until { events.all.count == 4 }
        #expect(events.all.suffix(2) == ["chunk fa", "done fa 1"])
    }

    // Breaks if a queued job cannot be cancelled before it starts.
    @Test func cancelRemovesAQueuedJob() async throws {
        let queue = TranslationQueue(translate: gate.translate)
        _ = queue.enqueue(job("fa"))
        _ = queue.enqueue(job("ku"))
        queue.cancel(key: "t|ku")
        #expect(queue.queued.isEmpty)
        gate.open("fa")
        try await until { queue.running == nil }
        #expect(gate.started.withLock { $0 } == ["fa"])
    }

    // Breaks if a failure does not reach the owner with its reason, or stops the queue.
    @Test func failureReachesTheOwnerAndTheQueueGoesOn() async throws {
        let queue = TranslationQueue(translate: gate.translate)
        gate.fail("fa")
        _ = queue.enqueue(job("fa"))
        _ = queue.enqueue(job("ku"))
        gate.open("fa")
        gate.open("ku")
        try await until { events.all.count == 3 }
        #expect(events.all == ["failed fa Quota exceeded", "chunk ku", "done ku 1"])
        #expect(queue.running == nil)
    }

    // Breaks if progress does not reach the running job's row.
    @Test func progressIsShown() async throws {
        let queue = TranslationQueue(translate: { job, progress, _ in
            progress(0.25)
            while true { try await Task.sleep(for: .milliseconds(5)) }
        })
        _ = queue.enqueue(job("fa"))
        try await until { queue.running?.progress == 0.25 }
        queue.cancel(key: "t|fa")
    }
}
