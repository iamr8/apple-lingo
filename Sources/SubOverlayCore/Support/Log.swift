import os

/// Logs never contain tokens, subtitle text, or URLs with query strings.
public enum Log {
    public static let adapter = Logger(subsystem: "local.SubOverlay", category: "adapter")
    public static let ingest = Logger(subsystem: "local.SubOverlay", category: "ingest")
    public static let overlay = Logger(subsystem: "local.SubOverlay", category: "overlay")
    public static let translation = Logger(subsystem: "local.SubOverlay", category: "translation")
}
