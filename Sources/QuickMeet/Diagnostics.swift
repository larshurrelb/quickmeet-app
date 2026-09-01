import Foundation

/// A small append-only log, so a failure can be inspected instead of guessed at.
///
/// A meeting is long and expensive to reproduce — you cannot ask four people to have the
/// same conversation again because the transcript came back empty. So this logs more
/// than its QuickTalk ancestor did: every capture device, every chunk, every request.
/// It still never logs the API key, and never logs transcript text — only lengths.
enum Diagnostics {
    static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("QuickMeet.log")
    }()

    private static let queue = DispatchQueue(label: "com.quickmeet.QuickMeet.diagnostics")
    private static var lastErrorText: String?

    /// Built once. An `ISO8601DateFormatter` is expensive to create, and this runs on
    /// every line — including from the transcription pipeline, per chunk.
    private static let stamps = ISO8601DateFormatter()

    static func log(_ message: String) {
        let line = "[\(stamps.string(from: Date()))] \(redacting(message))\n"

        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    static func recordError(_ message: String) {
        queue.sync { lastErrorText = redacting(message) }
        log("ERROR \(message)")
    }

    /// Last-ditch guard against a credential reaching the log.
    ///
    /// Nothing is supposed to pass the key in here — `KeyStore` logs failures only, and
    /// the transcriber puts it in a header, never a logged string. This exists because
    /// `Copy Diagnostics` puts the log on the clipboard, so a single careless
    /// `Diagnostics.log("\(request)")` added later would be a credential in a pasted bug
    /// report.
    ///
    /// Both Google key formats are covered: the older `AIza…` and the current `AQ.…`.
    static func redacting(_ message: String) -> String {
        keyPatterns.reduce(message) { text, pattern in
            pattern.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "…redacted…"
            )
        }
    }

    /// Compiled once rather than per call. `replacingOccurrences(options: .regularExpression)`
    /// builds a fresh regex every time, and this sits on the path of every logged line.
    private static let keyPatterns: [NSRegularExpression] = [
        "AIza[0-9A-Za-z_\\-]{10,}",
        "AQ\\.[0-9A-Za-z_\\-.]{10,}",
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static var lastError: String? {
        queue.sync { lastErrorText }
    }

    /// Everything needed to diagnose a failure, minus anything secret.
    static func report() -> String {
        let tail = (try? String(contentsOf: logURL, encoding: .utf8))?
            .split(separator: "\n")
            .suffix(80)
            .joined(separator: "\n") ?? "(no log yet)"

        return """
        QuickMeet diagnostics
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Last error: \(lastError ?? "none")

        Recent log:
        \(tail)
        """
    }
}
