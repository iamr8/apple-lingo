import Foundation

/// Splits a byte stream into UTF-8 lines. Lines longer than `maxLength` bytes are dropped.
public struct BoundedLineSplitter: Sendable {
    public let maxLength: Int
    private var buffer = Data()
    private var discarding = false

    public init(maxLength: Int) {
        self.maxLength = maxLength
    }

    public mutating func feed(_ chunk: Data) -> [String] {
        var lines: [String] = []
        var rest = chunk[...]
        while let nl = rest.firstIndex(of: 0x0A) {
            let part = rest[rest.startIndex..<nl]
            if !discarding, buffer.count + part.count <= maxLength {
                buffer.append(part)
                if let line = String(data: buffer, encoding: .utf8) { lines.append(line) }
            }
            buffer.removeAll(keepingCapacity: true)
            discarding = false
            rest = rest[rest.index(after: nl)...]
        }
        if !discarding {
            if buffer.count + rest.count <= maxLength {
                buffer.append(rest)
            } else {
                buffer.removeAll(keepingCapacity: true)
                discarding = true
            }
        }
        return lines
    }
}
