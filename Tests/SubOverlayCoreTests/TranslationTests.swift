import AnyLanguageModel
import Foundation
import Synchronization
import Testing
@testable import SubOverlayCore

final class StubTransport: HTTPTransport {
    let requests = Mutex<[URLRequest]>([])
    let reply: @Sendable (URLRequest) -> (Int, String)

    init(reply: @escaping @Sendable (URLRequest) -> (Int, String)) {
        self.reply = reply
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.withLock { $0.append(request) }
        let (status, body) = reply(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

struct GeminiProviderTests {
    static let pong = LanguageModelProviderTests.gemini(#"{"reply":"ok"}"#)

    // Breaks if speech, image, audio or live models are offered, if models without generateContent are offered, or the default is not the newest stable flash.
    @Test func modelListAndDefault() async throws {
        let body = """
        {"models":[
          {"name":"models/gemini-2.5-flash","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-3.0-flash","supportedGenerationMethods":["generateContent","countTokens"]},
          {"name":"models/gemini-3.5-flash-preview-09","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-3.0-pro","supportedGenerationMethods":["generateContent"]},
          {"name":"models/embedding-001","supportedGenerationMethods":["embedContent"]},
          {"name":"models/gemini-3.8-flash-tts","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-3.1-flash-image","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-2.5-flash-native-audio-latest","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-3.1-flash-live-preview","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-3.1-pro-preview-customtools","supportedGenerationMethods":["generateContent"]}
        ]}
        """
        let models = try await GeminiProvider.listModels(apiKey: "k", transport: StubTransport { _ in (200, body) })
        #expect(models == ["gemini-2.5-flash", "gemini-3.0-flash", "gemini-3.0-pro", "gemini-3.5-flash-preview-09"])
        #expect(GeminiProvider.flashCandidates(from: models) == ["gemini-3.0-flash", "gemini-2.5-flash"])
    }

    // Breaks if a listed model the key may not use is picked, or candidates are not tried newest first.
    @Test func picksFirstUsableFlash() async throws {
        let (session, id) = StubURLProtocol.session { req in
            req.url!.path.contains("gemini-3.0-flash") ? .init(status: 429, body: #"{"error":{"message":"Quota exceeded, limit: 0"}}"#) : Self.pong
        }
        let model = try await GeminiProvider.firstUsableModel(from: ["gemini-2.5-flash", "gemini-3.0-flash", "gemini-3.0-pro"],
                                                              apiKey: "k", session: session)
        #expect(model == "gemini-2.5-flash")
        #expect(StubURLProtocol.recorded(id).map { $0.url!.lastPathComponent }
            == ["gemini-3.0-flash:generateContent", "gemini-2.5-flash:generateContent"])
    }

    static let modelList = """
    {"models":[{"name":"models/gemini-3.6-flash","supportedGenerationMethods":["generateContent"]},
               {"name":"models/gemini-3.8-flash","supportedGenerationMethods":["generateContent"]}]}
    """

    // Breaks if Authenticate with "Newest Flash" does not ping models and pick the first that answers.
    @Test func authenticatePicksUsableModel() async throws {
        let (session, _) = StubURLProtocol.session { req in
            req.url!.path.contains("3.8") ? .init(status: 429, body: "{}") : Self.pong
        }
        let result = try await GeminiProvider.authenticate(apiKey: "k", model: "", transport: StubTransport { _ in (200, Self.modelList) },
                                                           session: session)
        #expect(result.model == "gemini-3.6-flash")
        #expect(result.models == ["gemini-3.6-flash", "gemini-3.8-flash"])
    }

    // Breaks if a chosen model is not pinged, so a key that cannot use it still passes.
    @Test func authenticatePingsChosenModel() async {
        let (session, id) = StubURLProtocol.session { _ in .init(status: 403, body: #"{"error":{"message":"Model not enabled"}}"#) }
        do {
            _ = try await GeminiProvider.authenticate(apiKey: "k", model: "gemini-3.6-flash", transport: StubTransport { _ in (200, Self.modelList) },
                                                      session: session)
            Issue.record("no error")
        } catch {
            #expect(error.localizedDescription.contains("Model not enabled"))
        }
        #expect(StubURLProtocol.recorded(id).contains { $0.url!.path.hasSuffix("gemini-3.6-flash:generateContent") })
    }

    // Breaks if no usable model is reported as success, or the server's reason is lost.
    @Test func noUsableModelThrowsLastError() async {
        let (session, _) = StubURLProtocol.session { _ in .init(status: 403, body: #"{"error":{"message":"Model not enabled"}}"#) }
        do {
            _ = try await GeminiProvider.firstUsableModel(from: ["gemini-2.5-flash"], apiKey: "k", session: session)
            Issue.record("no error")
        } catch {
            #expect(error.localizedDescription.contains("Model not enabled"))
        }
    }
}

/// The first word of a line, as a model copies it.
func firstWord(_ text: String) -> String {
    String(text.split(whereSeparator: \.isWhitespace).first ?? "")
}

/// Answers style-sheet calls with `styleSheet` and chunk calls by echoing ids.
final class EchoProvider: TranslationProvider {
    let calls = Mutex<[String]>([])
    let systems = Mutex<[String]>([])
    let styleSheet: String
    let transform: @Sendable (Int, String) -> String
    let failFirst: Int
    private let failures = Mutex(0)

    init(failFirst: Int = 0, styleSheet: String = #"{"register":"spoken","tone":"dry"}"#,
         transform: @escaping @Sendable (Int, String) -> String = { _, t in "T:" + t }) {
        self.failFirst = failFirst
        self.styleSheet = styleSheet
        self.transform = transform
    }

    func complete(system: String, user: String, schema: GenerationSchema) async throws -> Data {
        calls.withLock { $0.append(user) }
        systems.withLock { $0.append(system) }
        let input = try JSONDecoder().decode(JSONValue.self, from: Data(user.utf8))
        guard case .object(let o) = input, case .array(let items)? = o["translate"] else {
            return Data(styleSheet.utf8)
        }
        if failures.withLock({ n in n += 1; return n <= failFirst }) {
            return Data("[]".utf8)
        }
        let out: [JSONValue] = items.map { item in
            guard case .object(let c) = item, let id = c["id"]?.number, let text = c["text"]?.string else { return .null }
            return .object(["cue": .number(id), "source_word": .string(firstWord(c["guide"]?.string ?? text)),
                            "text": .string(transform(Int(id), text))])
        }
        return try JSONEncoder().encode(JSONValue.object(["items": .array(out)]))
    }
}

struct TranslationPipelineTests {
    func cues(_ n: Int, text: String = "line") -> [Cue] {
        (1...n).map { Cue(id: $0, start: Double($0), end: Double($0) + 0.5, text: "\(text) \($0)", settings: "line:85%,start", italic: $0 == 2) }
    }

    func job(_ source: [Cue], timing: [Cue]? = nil, target: String = "fa") -> TranslationJob {
        guard let timing else { return TranslationJob(source: source, sourceLanguage: "en", targetLanguage: target) }
        return TranslationJob(source: source, sourceLanguage: "en", timing: timing, timingLanguage: "ar", targetLanguage: target)
    }

    func items(_ provider: EchoProvider) throws -> [[String: JSONValue]] {
        guard case .array(let items)? = try chunkRequest(provider)["translate"] else { return [] }
        return items.compactMap { if case .object(let o) = $0 { o } else { nil } }
    }

    func chunkRequest(_ provider: EchoProvider) throws -> [String: JSONValue] {
        let user = try #require(provider.calls.withLock { $0.first { $0.contains("\"translate\"") } })
        guard case .object(let o) = try JSONDecoder().decode(JSONValue.self, from: Data(user.utf8)) else { throw CancellationError() }
        return o
    }

    // Breaks if cues lose their reading-speed budget: 17 chars per second, 8 to 84.
    @Test func chunkItemsCarryCharBudget() async throws {
        let base = [Cue(id: 1, start: 0, end: 0.3, text: "Hi"), Cue(id: 2, start: 1, end: 4, text: "Long line"),
                    Cue(id: 3, start: 5, end: 20, text: "Speech")]
        let provider = EchoProvider()
        _ = try await TranslationPipeline(provider: provider, retryDelay: .zero).translate(job(base)) { _ in }
        guard case .array(let items)? = try chunkRequest(provider)["translate"] else { Issue.record("no translate"); return }
        let budgets = items.compactMap { item -> Double? in
            guard case .object(let o) = item else { return nil }
            return o["max_chars"]?.number
        }
        #expect(budgets == [8, 51, 84])
    }

    // Breaks if the style sheet from the first pass does not reach every chunk request.
    @Test func styleSheetReachesChunks() async throws {
        let provider = EchoProvider(styleSheet: #"{"register":"street slang","characters":[{"name":"Jimmy","target":"جیمی"}]}"#)
        _ = try await TranslationPipeline(provider: provider, retryDelay: .zero).translate(job(cues(3))) { _ in }
        guard case .object(let sheet)? = try chunkRequest(provider)["style_sheet"] else { Issue.record("no style_sheet"); return }
        #expect(sheet["register"]?.string == "street slang")
    }

    // Breaks if Persian rules (half-space, Persian punctuation) are missing for Persian or sent to other languages.
    @Test func languageRulesOnlyForTheirLanguage() async throws {
        let fa = EchoProvider(), de = EchoProvider()
        _ = try await TranslationPipeline(provider: fa, retryDelay: .zero).translate(job(cues(2), target: "fa")) { _ in }
        _ = try await TranslationPipeline(provider: de, retryDelay: .zero).translate(job(cues(2), target: "de")) { _ in }
        #expect(fa.systems.withLock { $0.last! }.contains("U+200C"))
        #expect(!de.systems.withLock { $0.last! }.contains("U+200C"))
    }

    // Breaks if a cue with a line over 42 characters is not split near its middle (also when the
    // model broke it in two, seen as 11 + 45 characters), or a dialogue cue or short text changes.
    @Test func longLinesAreSplit() {
        let long = "یعنی چیزایی که فکرشم نمی‌کنی به هم ربط دارن واقعاً"
        #expect(long.count > 42)
        #expect(TranslationPipeline.balanced(long) == "یعنی چیزایی که فکرشم نمی‌کنی\nبه هم ربط دارن واقعاً")
        #expect(TranslationPipeline.balanced("short line") == "short line")
        #expect(TranslationPipeline.balanced(String(repeating: "x", count: 50)) == String(repeating: "x", count: 50))
        let two = "Jimmy Kane.\nA drug dealer who is a smooth talker. Everyone loves him."
        #expect(TranslationPipeline.balanced(two) == "Jimmy Kane. A drug dealer who is a\nsmooth talker. Everyone loves him.")
        let dialogue = "- Hi.\n- A drug dealer who is a smooth talker. Everyone loves him."
        #expect(TranslationPipeline.balanced(dialogue) == dialogue)
        let fits = "Jimmy Kane.\nA drug dealer and a smooth talker."
        #expect(TranslationPipeline.balanced(fits) == fits)
    }

    // Breaks if the pipeline output skips line balancing.
    @Test func outputIsBalanced() async throws {
        let provider = EchoProvider { _, _ in "one two three four five six seven eight nine ten" }
        let out = try await TranslationPipeline(provider: provider, retryDelay: .zero).translate(job(cues(1))) { _ in }
        #expect(out[0].text == "one two three four five\nsix seven eight nine ten")
    }

    // Breaks if a chunk exceeds 120 cues or 6000 chars.
    @Test func chunkLimits() {
        #expect(TranslationPipeline.chunks(cues(300)).map(\.count) == [120, 120, 60])
        let long = cues(10, text: String(repeating: "x", count: 1990))
        #expect(TranslationPipeline.chunks(long).map(\.count) == [3, 3, 3, 1])
    }

    // Breaks if output cues lose timing, settings or italic, or ids are mixed up.
    @Test func translatesKeepingTimings() async throws {
        let base = cues(250)
        let out = try await TranslationPipeline(provider: EchoProvider(), retryDelay: .zero).translate(job(base)) { _ in }
        #expect(out.count == 250)
        #expect(out.map(\.text) == base.map { "T:" + $0.text })
        #expect(out.map(\.start) == base.map(\.start))
        #expect(out[1].italic && !out[0].italic)
        #expect(out[0].settings == "line:85%,start")
    }

    // Breaks if chunks are sent without the context cues around them.
    @Test func chunkRequestCarriesContext() async throws {
        let provider = EchoProvider()
        _ = try await TranslationPipeline(provider: provider, retryDelay: .zero).translate(job(cues(250))) { _ in }
        let second = try #require(provider.calls.withLock { $0.first { $0.contains("\"line 111\"") && $0.contains("\"line 241\"") && $0.contains("\"translate\"") } })
        let input = try JSONDecoder().decode(JSONValue.self, from: Data(second.utf8))
        guard case .object(let o) = input, case .array(let before)? = o["context_before"], case .array(let after)? = o["context_after"] else {
            Issue.record("missing keys")
            return
        }
        #expect(before.count == 10)
        #expect(after.count == 10)
    }

    static let arabic = [Cue(id: 1, start: 10, end: 12, text: "كان علي"), Cue(id: 2, start: 12.1, end: 14, text: "أن أقابل رجلاً"),
                         Cue(id: 3, start: 20, end: 21, text: "حسناً")]
    static let english = [Cue(id: 1, start: 10, end: 14, text: "I had to see\na man about a dog."), Cue(id: 2, start: 30, end: 31, text: "Later.")]

    // Breaks if a cue of the timing track does not get the source lines spoken during it (a line
    // over two cues goes to both), or loses its own text as the guide.
    @Test func timingCuesCarrySourceAndGuide() async throws {
        let provider = EchoProvider()
        _ = try await TranslationPipeline(provider: provider, retryDelay: .zero).translate(job(Self.english, timing: Self.arabic)) { _ in }
        let sent = try items(provider)
        #expect(sent.map { $0["text"]?.string } == ["I had to see a man about a dog.", "I had to see a man about a dog.", ""])
        #expect(sent.map { $0["guide"]?.string } == ["كان علي", "أن أقابل رجلاً", "حسناً"])
    }

    // Breaks if the output does not follow the timing track's cues and times.
    @Test func outputFollowsTimingTrack() async throws {
        let out = try await TranslationPipeline(provider: EchoProvider(), retryDelay: .zero).translate(job(Self.english, timing: Self.arabic)) { _ in }
        #expect(out.map(\.start) == [10, 12.1, 20])
        #expect(out.count == 3)
    }

    // Breaks if the style sheet is built from the timing track instead of the source, or one
    // track jobs send a guide.
    @Test func styleSheetFromSourceAndNoGuideForOneTrack() async throws {
        let split = EchoProvider()
        _ = try await TranslationPipeline(provider: split, retryDelay: .zero).translate(job(Self.english, timing: Self.arabic)) { _ in }
        let sheet = try #require(split.calls.withLock { $0.first { !$0.contains("\"translate\"") } })
        #expect(sheet.contains("a man about a dog") && !sheet.contains("حسناً"))
        #expect(split.systems.withLock { $0.last! }.contains("Arabic"))

        let one = EchoProvider()
        _ = try await TranslationPipeline(provider: one, retryDelay: .zero).translate(job(cues(2))) { _ in }
        #expect(try items(one).allSatisfy { $0["guide"] == nil })
        #expect(!one.systems.withLock { $0.last! }.contains("guide"))
    }

    // Breaks if a bad reply is not retried.
    @Test func retriesBadReply() async throws {
        let out = try await TranslationPipeline(provider: EchoProvider(failFirst: 2), retryDelay: .zero).translate(job(cues(5))) { _ in }
        #expect(out.count == 5)
    }

    // Breaks if forbidden text reaches the output.
    @Test func rejectsUnsafeText() async {
        let provider = EchoProvider { _, _ in "a --> b" }
        await #expect(throws: TranslationPipeline.PipelineError.self) {
            _ = try await TranslationPipeline(provider: provider, retryDelay: .zero).translate(job(cues(3))) { _ in }
        }
    }

    // Breaks if validation lets HTML, blank lines or over-long text through.
    @Test func validationRules() {
        let ids = [1]
        func ok(_ t: String) -> Bool { TranslationPipeline.validate([.init(id: 1, text: t)], ids: ids) }
        #expect(ok("سلام\nدنیا"))
        #expect(ok("می\u{200C}خوام بدونم\u{200F}"))
        #expect(!ok("<i>x</i>"))
        #expect(!ok("a\n\nb"))
        #expect(!ok(String(repeating: "x", count: 201)))
        #expect(!ok("a\u{0007}b"))
        #expect(!TranslationPipeline.validate([.init(id: 2, text: "x")], ids: ids))
    }

    // Breaks if an HTTP error (quota, model not enabled) is reported as an invalid translation.
    @Test func providerErrorIsShown() async {
        struct Failing: TranslationProvider {
            func complete(system: String, user: String, schema: GenerationSchema) async throws -> Data {
                throw ProviderError.http(service: "Gemini", status: 429, message: "Quota exceeded")
            }
        }
        do {
            _ = try await TranslationPipeline(provider: Failing(), retryDelay: .zero).translate(job(cues(2))) { _ in }
            Issue.record("no error")
        } catch {
            #expect(error.localizedDescription.contains("Quota exceeded"))
        }
    }

    /// Echoes each chunk, then changes the reply with `edit`.
    struct EditingProvider: TranslationProvider {
        let edit: @Sendable ([JSONValue]) -> [JSONValue]
        func complete(system: String, user: String, schema: GenerationSchema) async throws -> Data {
            guard case .object(let o) = try JSONDecoder().decode(JSONValue.self, from: Data(user.utf8)),
                  case .array(let items)? = o["translate"] else { return Data("{}".utf8) }
            let out: [JSONValue] = items.map { item in
                guard case .object(let c) = item else { return .null }
                return .object(["cue": c["id"]!, "source_word": .string(firstWord(c["guide"]?.string ?? c["text"]?.string ?? "")),
                                "text": .string("T")])
            }
            return try JSONEncoder().encode(JSONValue.object(["items": .array(edit(out))]))
        }
    }

    // Breaks if a context cue the model also translated (an id outside the chunk) fails the chunk.
    @Test func extraIdsAreDropped() async throws {
        let provider = EditingProvider { $0 + [.object(["cue": .number(999), "text": .string("context")])] }
        let out = try await TranslationPipeline(provider: provider, retryDelay: .zero).translate(job(cues(3))) { _ in }
        #expect(out.map(\.text) == ["T", "T", "T"])
    }

    /// Records each request with `record`, answers with `inner`.
    struct Both: TranslationProvider {
        let record: EchoProvider
        let inner: EditingProvider
        func complete(system: String, user: String, schema: GenerationSchema) async throws -> Data {
            _ = try await record.complete(system: system, user: user, schema: schema)
            return try await inner.complete(system: system, user: user, schema: schema)
        }
    }

    /// The cue ids each recorded request asked for.
    func asked(_ provider: EchoProvider) -> [[Int]] {
        provider.calls.withLock { $0 }.compactMap { user -> [Int]? in
            guard case .object(let o) = try? JSONDecoder().decode(JSONValue.self, from: Data(user.utf8)),
                  case .array(let items)? = o["translate"] else { return nil }
            return items.compactMap { if case .object(let c) = $0 { c["id"]?.number.map(Int.init) } else { nil } }
        }
    }

    // Breaks if a reply that merged a cue away fails the chunk, or the retry asks for the whole chunk again.
    @Test func missingCuesAreAskedAgainAlone() async throws {
        let provider = EchoProvider()
        let merging = EditingProvider { items in items.count > 1 ? items.filter { $0 != items[1] } : items }
        let out = try await TranslationPipeline(provider: Both(record: provider, inner: merging), retryDelay: .zero)
            .translate(job(cues(4))) { _ in }
        #expect(out.map(\.text) == ["T", "T", "T", "T"])
        #expect(asked(provider) == [[1, 2, 3, 4], [2]])
    }

    // Breaks if two cues whose copied word is wrong in every group reply (a model habit for a
    // cue) are re-asked together, where the drift check rejects them again until the title fails.
    @Test func stubbornCopiesAreAskedOneByOne() async throws {
        let provider = EchoProvider()
        let stubborn = EditingProvider { items in
            items.count == 1 ? items : items.map { item in
                guard case .object(var c) = item, let id = c["cue"]?.number, id >= 2 else { return item }
                c["source_word"] = .string("other")
                return .object(c)
            }
        }
        let out = try await TranslationPipeline(provider: Both(record: provider, inner: stubborn), retryDelay: .zero)
            .translate(job(cues(3))) { _ in }
        #expect(out.map(\.text) == ["T", "T", "T"])
        #expect(asked(provider) == [[1, 2, 3], [2], [3]])
    }

    // Breaks if a reply whose items drifted is accepted: each id carries the next line's
    // translation, as Gemini did in one 120-cue chunk of Hand to Mouth (lines 1-5 cues early).
    // Each item copies its line's first word; another line's word sends the item back.
    @Test func driftedReplyIsAskedAgain() async throws {
        struct Drifting: TranslationProvider {
            func complete(system: String, user: String, schema: GenerationSchema) async throws -> Data {
                guard case .object(let o) = try JSONDecoder().decode(JSONValue.self, from: Data(user.utf8)),
                      case .array(let items)? = o["translate"] else { return Data("{}".utf8) }
                let lines: [(id: JSONValue, text: String)] = items.compactMap {
                    if case .object(let c) = $0, let id = c["id"], let text = c["text"]?.string { (id, text) } else { nil }
                }
                let out: [JSONValue] = lines.indices.map { i in
                    let said = lines[min(i + 1, lines.count - 1)].text
                    return .object(["cue": lines[i].id, "source_word": .string(firstWord(said)), "text": .string("T:" + said)])
                }
                return try JSONEncoder().encode(JSONValue.object(["items": .array(out)]))
            }
        }
        let base = ["alpha", "bravo", "charlie", "delta"].enumerated().map {
            Cue(id: $0 + 1, start: Double($0), end: Double($0) + 0.5, text: "\($1) line")
        }
        let out = try await TranslationPipeline(provider: Drifting(), retryDelay: .zero).translate(job(base)) { _ in }
        #expect(out.map(\.text) == ["T:alpha line", "T:bravo line", "T:charlie line", "T:delta line"])
    }

    // Breaks if a lone cue is sent back for its copied word: one item cannot drift, and a model
    // may copy a word with other letters.
    @Test func loneCueIsNotCheckedForDrift() async throws {
        let provider = EditingProvider { $0.map { item in
            guard case .object(var c) = item else { return item }
            c["source_word"] = .string("other")
            return .object(c)
        } }
        let out = try await TranslationPipeline(provider: provider, retryDelay: .zero).translate(job(cues(1))) { _ in }
        #expect(out.map(\.text) == ["T"])
    }

    // Breaks if a reply that swaps number groups (612-5711 → ۵۷۱۱-۶۱۲, seen with an Arabic base)
    // is accepted, or a correct one in Persian digits is rejected.
    @Test func swappedNumbersAreRejected() async {
        let phone = [Cue(id: 1, start: 1, end: 3, text: "612-5711.")]
        let swapped = EchoProvider { _, _ in "۵۷۱۱-۶۱۲." }
        do {
            _ = try await TranslationPipeline(provider: swapped, retryDelay: .zero).translate(job(phone)) { _ in }
            Issue.record("no error")
        } catch {
            #expect(error.localizedDescription.contains("cue 1 changes the order of numbers"))
        }
        let right = EchoProvider { _, _ in "۶۱۲-۵۷۱۱." }
        let out = try? await TranslationPipeline(provider: right, retryDelay: .zero).translate(job(phone)) { _ in }
        #expect(out?.first?.text == "۶۱۲-۵۷۱۱.")
    }

    // Breaks if numbers that stand apart in a sentence ("a '79 Dodge B200", which Persian says
    // as "Dodge B200 model 79", as on The Place I Lie) are treated like a swapped phone number.
    @Test func separateNumbersMayMove() async throws {
        let car = [Cue(id: 1, start: 1, end: 3, text: "for a '79 Dodge B200")]
        let moved = EchoProvider { _, _ in "دوج بی ۲۰۰ مدل ۷۹" }
        let out = try await TranslationPipeline(provider: moved, retryDelay: .zero).translate(job(car)) { _ in }
        #expect(out.first?.text == "دوج بی ۲۰۰ مدل ۷۹")
    }

    // Breaks if "invalid translation" does not say what was wrong.
    @Test func invalidReplySaysWhy() async {
        let provider = EditingProvider { Array($0.dropLast()) }
        do {
            _ = try await TranslationPipeline(provider: provider, retryDelay: .zero).translate(job(cues(3))) { _ in }
            Issue.record("no error")
        } catch {
            #expect(error.localizedDescription.contains("missing cue 3"))
        }
    }

    // Breaks if the failure names one cue while most of the chunk was rejected.
    @Test func failureCountsRejectedCues() async {
        let provider = EditingProvider { Array($0.dropLast(2)) }
        do {
            _ = try await TranslationPipeline(provider: provider, retryDelay: .zero).translate(job(cues(3))) { _ in }
            Issue.record("no error")
        } catch {
            #expect(error.localizedDescription.contains("2 of 3 cues rejected; missing cue 2"))
        }
    }

    // Breaks if a retry log line hides a provider error's status and reason.
    @Test func retryReasonKeepsProviderDetail() {
        struct Odd: Error {}
        #expect(TranslationPipeline.reason(for: ProviderError.http(service: "Gemini", status: 429, message: "Quota exceeded"))
            == "Gemini returned HTTP 429. Quota exceeded")
        #expect(TranslationPipeline.reason(for: Odd()) == "Odd")
    }

    // Breaks if cancellation does not stop the job.
    @Test func cancellationStops() async {
        let provider = EchoProvider()
        let task = Task {
            try await TranslationPipeline(provider: provider, retryDelay: .zero).translate(job(cues(2000))) { _ in }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
