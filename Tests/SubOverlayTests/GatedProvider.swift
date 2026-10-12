import AnyLanguageModel
import Foundation
import SubOverlayCore
import Synchronization

/// Echoes each cue's text once `open()` is called, so a test can act while a translation runs.
final class GatedProvider: TranslationProvider {
    let calls = Mutex(0)
    private let opened = Mutex(false)

    func open() { opened.withLock { $0 = true } }

    func complete(system: String, user: String, schema: GenerationSchema) async throws -> Data {
        calls.withLock { $0 += 1 }
        while !opened.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        let input = try JSONDecoder().decode(SubOverlayCore.JSONValue.self, from: Data(user.utf8))
        guard case .object(let o) = input, case .array(let items)? = o["translate"] else {
            return Data(#"{"register":"spoken"}"#.utf8)
        }
        let out: [SubOverlayCore.JSONValue] = items.map { item in
            guard case .object(let c) = item, let id = c["id"]?.number, let text = c["text"]?.string else { return .null }
            let line = c["guide"]?.string ?? text
            return .object(["cue": .number(id), "source_word": .string(String(line.split(separator: " ").first ?? "")),
                            "text": .string("T:" + text)])
        }
        return try JSONEncoder().encode(SubOverlayCore.JSONValue.object(["items": .array(out)]))
    }
}
