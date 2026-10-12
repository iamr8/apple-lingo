import AnyLanguageModel
import Foundation

/// What to translate. `source` gives the meaning (the film's original language for accuracy);
/// `timing` gives the output cues: their times and breaks. For a right-to-left target, a
/// right-to-left Apple track splits the dialogue the way that target reads.
public struct TranslationJob: Sendable {
    public var source: [Cue]
    public var sourceLanguage: String
    public var timing: [Cue]
    public var timingLanguage: String
    public var targetLanguage: String

    public init(source: [Cue], sourceLanguage: String, timing: [Cue], timingLanguage: String, targetLanguage: String) {
        self.source = source
        self.sourceLanguage = sourceLanguage
        self.timing = timing
        self.timingLanguage = timingLanguage
        self.targetLanguage = targetLanguage
    }

    /// One track gives both meaning and timing.
    public init(source: [Cue], sourceLanguage: String, targetLanguage: String) {
        self.init(source: source, sourceLanguage: sourceLanguage, timing: source, timingLanguage: sourceLanguage, targetLanguage: targetLanguage)
    }

    /// The timing cues come from another track, so each carries its own text as a guide.
    var split: Bool { timingLanguage != sourceLanguage }
}

/// Translates a base track. Pass 1 builds a style sheet (characters, forms of address, register,
/// terms, idioms) from the whole film; pass 2 translates chunks with context and a per-cue
/// reading-speed budget, at most 3 in flight. Output keeps the base track's timings and settings.
public actor TranslationPipeline {
    public enum PipelineError: Error, LocalizedError {
        /// The reason names cue ids and the failed rule, never subtitle text.
        case badReply(String)

        public var errorDescription: String? {
            switch self {
            case .badReply(let reason): "The model kept returning an invalid translation (\(reason))."
            }
        }
    }

    struct Item: Codable, Sendable, Equatable {
        var id: Int
        var text: String
    }

    /// A cue to translate with `max_chars`, the most characters a viewer can read in its time.
    /// With a separate timing track, `text` is the source spoken during the cue and `guide` is
    /// the timing track's own text for it.
    struct SourceItem: Codable, Sendable {
        var id: Int
        var text: String
        var guide: String?
        var max_chars: Int
    }

    struct ChunkInput: Codable, Sendable {
        var style_sheet: JSONValue
        var context_before: [Item]
        var translate: [SourceItem]
        var context_after: [Item]
    }

    struct StyleSheetInput: Codable, Sendable {
        var cues: [Item]
    }

    static let maxChunkCues = 120
    static let maxChunkChars = 6000
    static let contextCues = 10
    static let parallelChunks = 3
    static let attempts = 4
    static let maxTextLength = 200
    /// Reading speed for the per-cue budget, characters per second.
    static let charsPerSecond = 17.0
    static let maxLineLength = 42

    private let provider: TranslationProvider
    private let retryDelay: Duration

    public init(provider: TranslationProvider, retryDelay: Duration = .seconds(1)) {
        self.provider = provider
        self.retryDelay = retryDelay
    }

    public func translate(_ job: TranslationJob, progress: @escaping @Sendable (Double) -> Void) async throws -> [Cue] {
        try Task.checkCancellation()
        let chunks = Self.chunks(job.timing)
        let steps = Double(chunks.count + 1)
        let styleSheet = try await styleSheet(job)
        progress(1 / steps)

        var results: [Int: String] = [:]
        let inputs = chunks.map { Array($0.indices) }
        let system = chunkSystemPrompt(job)
        try await withThrowingTaskGroup(of: [Item].self) { group in
            var next = 0
            func addNext() {
                guard next < inputs.count else { return }
                let input = inputs[next]
                next += 1
                group.addTask { try await self.translateChunk(input, job: job, styleSheet: styleSheet, system: system) }
            }
            for _ in 0..<Self.parallelChunks { addNext() }
            var done = 0
            while let items = try await group.next() {
                for item in items { results[item.id] = item.text }
                done += 1
                progress(Double(done + 1) / steps)
                addNext()
            }
        }
        return job.timing.map { cue in
            var out = cue
            out.text = results[cue.id].map(Self.balanced) ?? cue.text
            return out
        }
    }

    /// Consecutive cue ranges of at most 120 cues and 6000 characters.
    static func chunks(_ cues: [Cue]) -> [ArraySlice<Cue>] {
        var result: [ArraySlice<Cue>] = []
        var start = 0, chars = 0
        for (i, cue) in cues.enumerated() {
            if i > start, i - start == maxChunkCues || chars + cue.text.count > maxChunkChars {
                result.append(cues[start..<i])
                start = i
                chars = 0
            }
            chars += cue.text.count
        }
        if start < cues.count { result.append(cues[start...]) }
        return result
    }

    /// A text with a line over 42 characters, as one line split at the space nearest its middle.
    /// Dialogue (lines starting "-") and text that fits stay as they are.
    static func balanced(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.contains(where: { $0.count > maxLineLength }), !lines.contains(where: { $0.hasPrefix("-") }) else { return text }
        let text = lines.joined(separator: " ")
        let middle = text.count / 2
        let spaces = text.indices.filter { text[$0] == " " }
        guard let cut = spaces.min(by: { abs(text.distance(from: text.startIndex, to: $0) - middle) < abs(text.distance(from: text.startIndex, to: $1) - middle) })
        else { return text }
        return text[..<cut] + "\n" + text[text.index(after: cut)...]
    }

    /// Characters a viewer can read during a cue: 17 per second, 8 to 84 (two full lines).
    static func charBudget(_ cue: Cue) -> Int {
        max(8, min(2 * maxLineLength, Int((cue.end - cue.start) * charsPerSecond)))
    }

    static func validate(_ items: [Item], ids: [Int]) -> Bool { problem(items, ids: ids) == nil }

    /// Why a reply is invalid, or nil. Ids must match the input exactly; text must be short plain lines.
    static func problem(_ items: [Item], ids: [Int]) -> String? {
        let got = Set(items.map(\.id))
        if let missing = ids.first(where: { !got.contains($0) }) { return "missing cue \(missing)" }
        if items.count != ids.count || got != Set(ids) { return "cue ids do not match" }
        return items.lazy.compactMap(textProblem).first
    }

    /// Why one cue's text is invalid, or nil.
    static func textProblem(_ item: Item) -> String? {
        let t = item.text
        if t.count > maxTextLength { return "cue \(item.id) is too long" }
        if t.contains("-->") || t.contains("<") || t.contains(">") { return "cue \(item.id) has markup" }
        if t.contains("\n\n") { return "cue \(item.id) has a blank line" }
        // Only Cc: format characters such as the Persian half-space (U+200C) are valid text.
        if t.unicodeScalars.contains(where: { $0 != "\n" && $0.properties.generalCategory == .control }) {
            return "cue \(item.id) has a control character"
        }
        return nil
    }

    /// The first word of a line with letters or digits, without marks or punctuation, lowercased.
    static func firstWord(_ text: String) -> String {
        for word in text.split(whereSeparator: \.isWhitespace) {
            let kept = word.unicodeScalars.filter {
                switch $0.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: true
                default: false
                }
            }
            if !kept.isEmpty { return String(String.UnicodeScalarView(kept)).lowercased() }
        }
        return ""
    }

    /// A reply that keeps the parts of a compound number (a phone number, a time, a date) but
    /// in another order, such as a phone number written right to left. Numbers that stand apart
    /// may move with the sentence. Persian and Arabic digits count as their ASCII values.
    static func numberProblem(_ item: Item, source: String) -> String? {
        func compounds(_ text: String) -> [[String]] {
            let ascii = String(text.unicodeScalars.map { scalar -> Character in
                if let v = scalar.properties.numericType == .decimal ? scalar.properties.numericValue : nil { return Character(String(Int(v))) }
                return Character(scalar)
            })
            return ascii.matches(of: /\d+(?:[-:.\/]\d+)+/).map { $0.output.split { "-:./".contains($0) }.map(String.init) }
        }
        let want = compounds(source), got = compounds(item.text)
        for parts in want where !got.contains(parts) && got.contains(where: { $0.sorted() == parts.sorted() }) {
            return "cue \(item.id) changes the order of numbers"
        }
        return nil
    }

    /// Translates the cues at `indices` of the base track. Valid cues of a reply are kept; cues the
    /// model left out (often merged into a neighbour) or broke are asked for again one at a time,
    /// where a reply cannot drift, so a wrong copied word the model repeats cannot fail the title.
    private func translateChunk(_ indices: [Int], job: TranslationJob, styleSheet: JSONValue, system: String) async throws -> [Item] {
        var done: [Item] = []
        var remaining = indices
        var attempt = 0
        var alone = false
        while true {
            try Task.checkCancellation()
            let input = chunkInput(alone ? [remaining[0]] : remaining, job: job, styleSheet: styleSheet)
            let ids = input.translate.map(\.id)
            do {
                let user = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
                let data = try await provider.complete(system: system, user: user, schema: ChunkReply.generationSchema)
                struct Reply: Decodable {
                    struct CueText: Decodable {
                        var cue: Int
                        var source_word: String?
                        var text: String
                    }
                    var items: [CueText]
                }
                guard let decoded = try? JSONDecoder().decode(Reply.self, from: data).items else {
                    throw PipelineError.badReply("not a cue list")
                }
                let reply = decoded.map { Item(id: $0.cue, text: $0.text) }
                // A reply can drift: each id gets another line's translation. Each item copies its
                // line's first word; one alone cannot drift.
                let heads = Dictionary(input.translate.map { ($0.id, Self.firstWord($0.guide ?? $0.text)) }, uniquingKeysWith: { a, _ in a })
                let starts = Dictionary(decoded.map { ($0.cue, Self.firstWord($0.source_word ?? "")) }, uniquingKeysWith: { a, _ in a })
                let drifted = { (item: Item) -> String? in
                    guard ids.count > 1, let head = heads[item.id], !head.isEmpty, starts[item.id] != head else { return nil }
                    return "cue \(item.id) does not match its line"
                }
                // Models sometimes also translate a context cue; ids outside the request are dropped.
                let wanted = Set(ids)
                let sources = Dictionary(input.translate.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
                let problem = { (item: Item) in
                    Self.textProblem(item) ?? Self.numberProblem(item, source: sources[item.id] ?? "") ?? drifted(item)
                }
                var seen = Set<Int>()
                let good = reply.filter { wanted.contains($0.id) && problem($0) == nil && seen.insert($0.id).inserted }
                done += good
                remaining = remaining.filter { !seen.contains(job.timing[$0].id) }
                if remaining.isEmpty { return done }
                // Progress: the leftovers follow one by one, with no retry wait.
                if !good.isEmpty {
                    alone = true
                    continue
                }
                let missing = job.timing[remaining[0]].id
                let why = reply.first { $0.id == missing }.flatMap(problem) ?? "missing cue \(missing)"
                throw PipelineError.badReply(remaining.count > 1 ? "\(remaining.count) of \(indices.count) cues rejected; \(why)" : why)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                if attempt >= Self.attempts { throw error }
                Log.translation.error("attempt \(attempt) failed: \(Self.reason(for: error), privacy: .public)")
                try await Task.sleep(for: retryDelay * (1 << (attempt - 1)))
            }
        }
    }

    private func styleSheet(_ job: TranslationJob) async throws -> JSONValue {
        let input = StyleSheetInput(cues: job.source.map { Item(id: $0.id, text: $0.text) })
        let user = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let base = name(job.sourceLanguage), target = name(job.targetLanguage)
        let system = """
        You prepare a style sheet for translating the \(base) subtitles of a film or episode into \(target). \
        From the whole script: list each character with their name in \(target), gender (male, female or unknown) and role. \
        For each pair of characters who talk, give the \(target) form of address (for example informal or formal "you") \
        that fits their relationship; leave the list empty if \(target) has no such forms. \
        Choose one register for dialogue and describe the tone in one sentence. \
        List recurring terms, and the idioms or slang that need a non-literal \(target) rendering, with that rendering.
        """
        return try await withRetry {
            let data = try await self.provider.complete(system: system, user: user, schema: StyleSheet.generationSchema)
            return try JSONDecoder().decode(JSONValue.self, from: data)
        }
    }

    /// A request for the timing cues at `indices` (ascending), with context around them.
    private func chunkInput(_ indices: [Int], job: TranslationJob, styleSheet: JSONValue) -> ChunkInput {
        let cues = job.timing
        let first = indices.first ?? 0, last = indices.last ?? 0
        let before = cues[max(0, first - Self.contextCues)..<first]
        let after = cues[(last + 1)..<min(cues.count, last + 1 + Self.contextCues)]
        let text = { (c: Cue) in job.split ? Self.spoken(during: c, in: job.source) : c.text }
        return ChunkInput(
            style_sheet: styleSheet,
            context_before: before.map { Item(id: $0.id, text: text($0)) },
            translate: indices.map { cues[$0] }.map {
                SourceItem(id: $0.id, text: text($0), guide: job.split ? $0.text : nil, max_chars: Self.charBudget($0))
            },
            context_after: after.map { Item(id: $0.id, text: text($0)) }
        )
    }

    /// The source lines that overlap `cue` in time, as one line. A line spoken over two cues
    /// goes to both; the guide tells the model which part belongs where.
    static func spoken(during cue: Cue, in source: [Cue]) -> String {
        source.filter { min($0.end, cue.end) > max($0.start, cue.start) }
            .map { $0.text.replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: " ")
    }

    private func chunkSystemPrompt(_ job: TranslationJob) -> String {
        let base = name(job.sourceLanguage), target = name(job.targetLanguage)
        // One voice for the copied word: the model follows whichever of two rules it reads last.
        let copied = job.split ? "\"guide\" unchanged, in \(name(job.timingLanguage))" : "\"text\" unchanged, in \(base)"
        return """
        You are a professional subtitler translating \(base) subtitles into \(target).
        Rules:
        - Return exactly one item for each id in "translate", with that id in "cue". Never merge, split, drop or reorder cues. \
        "context_before" and "context_after" are context only.
        - In "source_word", copy the first word of the item's \(copied). Never translate it.
        - Keep the full meaning, intent, tone and register of each line. Translate idioms, slang and jokes by meaning, \
        not word for word. Never add explanations, notes or content that is not in the \(base).
        - Reading speed: each cue has "max_chars", the most characters a viewer can read in its time. Stay within it. \
        If the meaning does not fit, condense: drop fillers and repetition, use shorter words, keep what matters.
        - At most 2 lines of at most 42 characters. Use one line when it fits. Break lines at natural phrase boundaries; \
        never split a noun from its adjective, a preposition from its noun, or a number from its noun.
        - Two speakers in one cue: one line each, each line starts with "- ".
        - A sentence that runs across cues: keep each cue readable on its own, and keep the order of the \(base) \
        as far as \(target) grammar allows, so each cue matches what is said on screen.
        - Profanity and insults: match strength and intent. An angry insult stays as harsh; a friendly or admiring curse \
        becomes a friendly one in \(target). Never soften or censor, never make it harsher or change what it means.
        - Use \(target) words. No English loanwords or transliterated English slang when a common \(target) word exists.
        - Numbers, times and phone numbers keep the order of the source. Write every line in normal reading order; \
        never reverse text or numbers for right-to-left display.
        - Songs keep their ♪ marks. Signs and on-screen text go in quotation marks.
        - Follow the style sheet: names, forms of address per speaker pair, register, terms and idioms.
        - No notes and no markup.
        """ + splitNote(job) + (Self.languageRules[job.targetLanguage].map { "\n" + $0 } ?? "")
    }

    /// Extra rules for one target language.
    static let languageRules: [String: String] = [
        "fa": """
        Persian rules:
        - Write natural spoken Persian (محاوره) for dialogue, as Iranian subtitlers do: می‌خوام، نمی‌دونم، اینجا چی‌کار می‌کنی. \
        Use written Persian only for documents, signs and formal speeches.
        - Letters ی and ک only, never ي or ك. Use the half-space (U+200C) in می‌، ‌ها، ‌ای، ‌ام، ‌اند and compound words.
        - Punctuation: ، ؟ ؛ « » and one … character. Never use ASCII ? , " or '. Signs and on-screen text go in « ».
        - Numbers: words for one to ten, Persian digits (۰-۹) above ten. Do not convert currency.
        - Names: transliterate by sound, exactly as in the style sheet. No gender words that the source does not give.
        """,
    ]

    /// How to use a separate timing track: meaning from the source, cue breaks from the guide.
    private func splitNote(_ job: TranslationJob) -> String {
        guard job.split else { return "" }
        let source = name(job.sourceLanguage), timing = name(job.timingLanguage)
        return """

        Each item in "translate" has "text", the \(source) lines spoken while the cue is on screen, and "guide", \
        the \(timing) subtitle of that cue. Translate the meaning of "text". The guide shows which part of the \
        sentence belongs in this cue: cover that part, in \(name(job.targetLanguage)) word order. A \(source) line can \
        run over two cues: split its meaning the way the guides do, and never repeat it. If "text" is empty, translate the guide.
        """
    }

    private func withRetry<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await body()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                // Keep provider errors (quota, model not enabled) so the user sees the reason.
                if attempt >= Self.attempts { throw error is DecodingError ? PipelineError.badReply("not valid JSON") : error }
                Log.translation.error("attempt \(attempt) failed: \(Self.reason(for: error), privacy: .public)")
                try await Task.sleep(for: retryDelay * (1 << (attempt - 1)))
            }
        }
    }

    /// What a failed attempt logs: a pipeline or provider error's own words (cue ids, HTTP status,
    /// the server's reason; never subtitle text), else the error's type.
    static func reason(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: type(of: error))
    }

    private func name(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }
}

/// Reply shapes. The library turns them into each service's native schema. OpenAI needs an
/// object at the root, so a chunk's cues sit under "items".
@Generable
struct ChunkReply {
    /// `cue` is the cue's id; the macro reserves the name `id`.
    @Generable
    struct CueText {
        var cue: Int
        /// The first word of the cue's guide, or of its text, copied: shows the reply did not drift to another line.
        @Guide(description: "The first word of this cue's guide, or of its text when it has no guide, copied unchanged. Never translated.")
        var source_word: String
        var text: String
    }

    var items: [CueText]
}

@Generable
struct StyleSheet {
    @Generable
    struct Character {
        var name: String
        var target: String
        var gender: String
        var role: String
    }

    @Generable
    struct Address {
        var speaker: String
        var listener: String
        var form: String
    }

    @Generable
    struct Pair {
        var source: String
        var target: String
    }

    var register: String
    var tone: String
    var characters: [Character]
    var address: [Address]
    var terms: [Pair]
    var idioms: [Pair]
}
