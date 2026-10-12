import Foundation
import Testing
@testable import SubOverlayCore

/// Runs only when the adapter was built by `make deps`.
struct AdapterSmokeTests {
    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let paths = AdapterProcess.Paths(
        script: root.appending(path: "Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl"),
        framework: root.appending(path: "build/adapter/MediaRemoteAdapter.framework"),
        testClient: root.appending(path: "build/adapter/MediaRemoteAdapterTestClient"))
    static let built = FileManager.default.fileExists(atPath: paths.testClient.path)

    // Breaks if the arguments or environment stop the adapter from working.
    @Test(.enabled(if: built)) func selfTestPassesAndStreamEmits() async throws {
        let adapter = AdapterProcess(paths: Self.paths)
        #expect(await adapter.selfTest())
        var first: String?
        for await line in adapter.lines() { first = line; break }
        #expect(first?.contains(#""type":"data""#) == true)
    }
}
