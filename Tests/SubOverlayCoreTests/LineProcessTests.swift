import Foundation
import Testing
@testable import SubOverlayCore

struct LineProcessTests {
    // Breaks if a restart of the program is not marked in its output: the reader cannot know
    // that lines were lost.
    @Test func outputMarksARestart() async {
        let process = LineProcess(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "echo one"], maxLineLength: 100, name: "test")
        var seen: [LineProcess.Output] = []
        for await output in process.outputs() {
            seen.append(output)
            if seen.count == 2 { break }
        }
        #expect(seen == [.line("one"), .restarted])
    }
}
