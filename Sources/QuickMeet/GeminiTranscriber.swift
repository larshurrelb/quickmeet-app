import Foundation

/// One word as the transcribe model reports it.
struct TranscribedWord {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    /// `spk_1`, `spk_2`… Only present when diarization was asked for, and only meaningful
    /// within the single request that produced it.
    var speaker: String?
}

/// Gemini 3.5 Transcribe, in the shape a meeting needs.
///
/// The configuration here is deliberately *not* the one QuickTalk uses, and the reasons
/// are worth stating because each was a wrong turn first:
///
///  * **`mode` is an object, not a string.** `"mode": "smart"` is the shorthand for smart
///    transcription. Word timestamps and diarization live inside the long form,
///    `{"type": "verbatim", …}`. Sending the string with extra sibling keys parses and
///    silently gives you neither.
///  * **Smart mode is unavailable here.** The API rejects `smart` together with
///    `diarization_mode` or `timestamp_granularities`. Smart is what makes QuickTalk's
///    output readable, so losing it means the tidying has to happen downstream — which is
///    what `GeminiNotes` is for.
///  * **No `language_codes`.** Same prohibition as QuickTalk, same reason: omitting it is
///    what gives automatic per-utterance language detection, and a meeting is far more
///    likely to be bilingual than a dictation.
///  * **No `custom_vocabulary`.** It is documented as combinable with diarization and is
///    in fact rejected with HTTP 400 — `custom_vocabulary is incompatible with
///    diarization`. If someone adds a jargon list later, it cannot go here.
///
/// Diarization tops out at 8 speakers and is documented as experimental beyond 2, which is
/// the other half of why the microphone is recorded separately: the most important
/// speaker split in any meeting — you versus everyone else — never goes through it.
struct GeminiTranscriber {
    var apiKey: String
    var model = "gemini-3.5-transcribe"
    var endpoint = URL(string: "https://generativelanguage.googleapis.com")!
    /// A 20-minute chunk is a real upload and a real inference. The dictation app's 30s
    /// would time out most meetings.
    var timeout: TimeInterval = 300

    enum TranscribeError: LocalizedError {
        case noAPIKey
        case http(Int, String)
        case badResponse(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "No API key set. Open QuickMeet Settings and paste your Gemini key."
            case .http(401, _), .http(403, _):
                return "Gemini rejected the API key. Check it in Settings."
            case .http(429, _):
                return "Rate limited by Gemini. The meeting is saved — use Retry in a moment."
            case let .http(code, detail):
                return "Gemini returned HTTP \(code). \(detail)"
            case let .badResponse(reason):
                return "Couldn't read Gemini's response (\(reason))."
            case .empty:
                return "No speech was found in the recording."
            }
        }
    }

    /// Transcribes one compressed chunk.
    ///
    /// - Parameter diarize: on for the system stream, where several people share one
    ///   channel. Off for the microphone, which is one person by construction — asking for
    ///   diarization there would only invite the model to split one voice in two.
    func transcribe(chunk url: URL, diarize: Bool) async throws -> [TranscribedWord] {
        guard !apiKey.isEmpty else { throw TranscribeError.noAPIKey }

        let audio = try Data(contentsOf: url)
        Diagnostics.log("transcribe \(url.lastPathComponent) bytes=\(audio.count) diarize=\(diarize)")

        var mode: [String: Any] = [
            "type": "verbatim",
            // Without word timestamps the two streams cannot be interleaved — there would
            // be no way to know whether your sentence came before or after theirs.
            "timestamp_granularities": ["word"],
        ]
        if diarize { mode["diarization_mode"] = "speaker" }

        let body: [String: Any] = [
            "model": model,
            "input": [[
                "type": "audio",
                "mime_type": "audio/m4a",
                "data": audio.base64EncodedString(),
            ]],
            "generation_config": ["transcription_config": ["mode": mode]],
        ]

        var request = URLRequest(url: endpoint.appendingPathComponent("v1beta/interactions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The credential goes in the header, never the query string — a `?key=` lands in
        // proxy and crash logs verbatim.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TranscribeError.badResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = Self.errorMessage(from: data)
            Diagnostics.recordError("HTTP \(http.statusCode): \(detail.isEmpty ? Self.snippet(data) : detail)")
            throw TranscribeError.http(http.statusCode, detail)
        }

        let words = try Self.extractWords(from: data)
        Diagnostics.log(
            "transcribed \(url.lastPathComponent) words=\(words.count) "
            + "speakers=\(Set(words.compactMap(\.speaker)).count)"
        )
        return words
    }

    // MARK: - Response

    /// The interactions envelope is `{"status", "steps":[{"type","content":[…]}]}` — a
    /// different shape from `:generateContent`'s `candidates/content/parts`.
    ///
    /// Word timings arrive as `annotations` of type `word_info` hanging off a content
    /// entry, carrying `text`, `speaker`, `start_offset` and `end_offset`. Offsets are
    /// strings with a unit suffix: `"12.480s"`.
    static func extractWords(from data: Data) throws -> [TranscribedWord] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscribeError.badResponse("unparseable JSON")
        }

        let status = json["status"] as? String ?? "missing"
        guard status == "completed" else {
            throw TranscribeError.badResponse("status \(status)")
        }

        // Silence comes back as HTTP 200, status "completed" and no `steps` key at all.
        // The API does not treat "nobody spoke" as an error, and neither should we — half
        // the chunks of a real meeting are one side listening.
        guard let steps = json["steps"] as? [[String: Any]] else { return [] }

        let contents = steps
            .filter { ($0["type"] as? String) == "model_output" }
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }

        var words: [TranscribedWord] = []
        for content in contents {
            guard let annotations = content["annotations"] as? [[String: Any]] else { continue }
            for annotation in annotations {
                guard (annotation["type"] as? String) == "word_info" else { continue }
                guard let text = annotation["text"] as? String, !text.isEmpty else { continue }
                let start = seconds(annotation["start_offset"]) ?? seconds(annotation["startOffset"]) ?? 0
                let end = seconds(annotation["end_offset"]) ?? seconds(annotation["endOffset"]) ?? start
                let speaker = (annotation["speaker"] as? String) ?? (annotation["speakerLabel"] as? String)
                words.append(
                    TranscribedWord(text: text, start: start, end: end, speaker: speaker)
                )
            }
        }

        if !words.isEmpty { return words.sorted { $0.start < $1.start } }

        // Timestamps can be missing even on a 200 — a short chunk, or a model that
        // returned prose without annotations. Losing the audio would be far worse than
        // losing the timing, so fall back to the plain text as one undated block and let
        // the builder place it at the chunk's start.
        let text = contents
            .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return [] }
        Diagnostics.log("no word_info annotations — falling back to undated text (\(text.count) chars)")
        return [TranscribedWord(text: text, start: 0, end: 0, speaker: nil)]
    }

    /// `"12.480s"` → `12.48`. Accepts a bare number too, because the two documented
    /// clients disagree about whether the unit is included.
    static func seconds(_ value: Any?) -> TimeInterval? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        guard let text = value as? String else { return nil }
        return TimeInterval(text.hasSuffix("s") ? String(text.dropLast()) : text)
    }

    /// First 400 characters of a response body, for the log only.
    static func snippet(_ data: Data) -> String {
        String(decoding: data.prefix(400), as: UTF8.self)
    }

    static func errorMessage(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return "" }
        return message
    }
}
