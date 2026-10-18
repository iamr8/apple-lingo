import Foundation

/// Runs `mediaremote-adapter.pl` under /usr/bin/perl with fixed paths inside the app bundle.
public struct AdapterProcess: Sendable {
    public struct Paths: Sendable {
        public var script: URL
        public var framework: URL
        public var testClient: URL

        public init(script: URL, framework: URL, testClient: URL) {
            self.script = script
            self.framework = framework
            self.testClient = testClient
        }

        public static func inBundle(_ bundle: Bundle = .main) -> Paths {
            let contents = bundle.bundleURL.appending(path: "Contents")
            return Paths(
                script: contents.appending(path: "Resources/mediaremote-adapter.pl"),
                framework: contents.appending(path: "Frameworks/MediaRemoteAdapter.framework"),
                testClient: contents.appending(path: "Helpers/MediaRemoteAdapterTestClient")
            )
        }
    }

    static let perl = URL(filePath: "/usr/bin/perl")
    static let maxLineLength = 64 * 1024

    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    /// Exit code 0 of the adapter's `test` command means MediaRemote access works.
    public func selfTest() async -> Bool {
        await process([paths.script.path, paths.framework.path, paths.testClient.path, "test"]).run(onOutput: nil) == 0
    }

    /// Adapter `stream` output lines. Restarts the adapter after a crash, at most 3 times.
    /// Cancelling the consumer terminates the process.
    public func lines() -> AsyncStream<String> {
        process([paths.script.path, paths.framework.path, "stream", "--no-artwork", "--micros", "--debounce=50"]).lines()
    }

    private func process(_ arguments: [String]) -> LineProcess {
        LineProcess(executable: Self.perl, arguments: arguments, maxLineLength: Self.maxLineLength, name: "adapter")
    }
}
