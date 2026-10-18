import os

/// Logs never contain tokens, subtitle text, or URLs with query strings.
public enum Log {
    public static let adapter = Logger(subsystem: "local.AppleLingo", category: "adapter")
    public static let ingest = Logger(subsystem: "local.AppleLingo", category: "ingest")
    public static let overlay = Logger(subsystem: "local.AppleLingo", category: "overlay")
    public static let translation = Logger(subsystem: "local.AppleLingo", category: "translation")
}
