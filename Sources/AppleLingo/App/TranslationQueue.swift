import Foundation
import Observation
import AppleLingoCore

/// Translations in order, one at a time, keyed by title folder and target. A key already
/// queued or running is not added again. Each job's owner gets its chunks and its result;
/// nothing of a cancelled job reaches the owner. A failed job leaves the queue; the next play
/// of its title or a Settings change may queue it again.
@MainActor
@Observable
final class TranslationQueue {
    typealias Translate = @Sendable (TranslationJob, _ progress: @escaping @Sendable (Double) -> Void,
                                     _ chunk: @escaping @Sendable ([Cue]) -> Void) async throws -> [Cue]

    struct Job: Identifiable {
        let id = UUID()
        let key: String
        let title: String
        let target: String
        /// The job with its languages fixed when queued; its cues are read when it starts.
        let make: @MainActor () throws -> TranslationJob
        let chunk: @MainActor ([Cue]) -> Void
        let done: @MainActor (Result<[Cue], Error>) -> Void
        var progress = 0.0
    }

    private(set) var running: Job?
    private(set) var queued: [Job] = []
    @ObservationIgnored private let translate: Translate
    @ObservationIgnored private var task: Task<Void, Never>?

    init(translate: @escaping Translate) {
        self.translate = translate
    }

    /// False when the key is queued or running already.
    @discardableResult
    func enqueue(_ job: Job) -> Bool {
        guard running?.key != job.key, !queued.contains(where: { $0.key == job.key }) else { return false }
        queued.append(job)
        startNext()
        return true
    }

    func cancel(key: String) {
        queued.removeAll { $0.key == key }
        if running?.key == key {
            task?.cancel()
            task = nil
            running = nil
            startNext()
        }
    }

    private func startNext() {
        guard running == nil, !queued.isEmpty else { return }
        let job = queued.removeFirst()
        running = job
        let id = job.id
        task = Task { [translate] in
            let result: Result<[Cue], Error>
            do {
                let input = try job.make()
                result = .success(try await translate(input, { progress in
                    Task { @MainActor in self.update(id) { $0.progress = progress } }
                }, { cues in
                    Task { @MainActor in if self.running?.id == id { job.chunk(cues) } }
                }))
            } catch {
                result = .failure(error)
            }
            guard running?.id == id else { return }
            running = nil
            task = nil
            job.done(result)
            startNext()
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard var job = running, job.id == id else { return }
        change(&job)
        running = job
    }
}
