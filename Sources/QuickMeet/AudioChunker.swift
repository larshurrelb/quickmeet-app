import AVFoundation
import Foundation

/// Slices a recording into pieces the transcribe API will accept, and compresses them.
///
/// Two hard limits shape this. Speaker diarization caps a request at **30 minutes** of
/// audio, and an inline request body is not the place for an hour of PCM — 16 kHz mono
/// PCM is 115 MB per hour, and base64 adds a third on top. Encoding each slice to AAC
/// takes that to roughly 14 MB per hour, which fits inline comfortably and removes the
/// need for a separate upload protocol.
///
/// Slices **overlap**, and that is load-bearing rather than defensive: `TranscriptBuilder`
/// uses the overlap to work out that chunk 2's `spk_1` is chunk 1's `spk_2`. Speaker
/// labels are only meaningful within a single request, so without a shared stretch of
/// audio to compare, a long meeting would rename everybody every twenty minutes.
enum AudioChunker {
    /// Comfortably inside the 30-minute diarization ceiling, with room for the overlap.
    static let chunkSeconds: TimeInterval = 20 * 60
    /// Long enough to contain several speaker turns to match on, short enough to be cheap.
    static let overlapSeconds: TimeInterval = 20

    /// Below this peak the slice is silence and never leaves the machine. On the system
    /// stream that is most of a one-sided meeting; on the mic stream it is you listening.
    /// QuickTalk measured the same boundary: silence peaks at 0.000–0.002, speech at
    /// 0.019 and up.
    static let silenceThreshold: Float = 0.006

    struct Chunk {
        /// Seconds from the start of the whole recording — every timestamp the model
        /// returns is relative to the chunk, so this is what puts it back on the meeting's
        /// clock.
        let offset: TimeInterval
        let duration: TimeInterval
        let url: URL
        /// A silent chunk still occupies its place on the timeline; it just has no audio
        /// worth spending a request on.
        let isSilent: Bool
    }

    enum ChunkError: LocalizedError {
        case unreadable(URL)
        case encodeFailed(String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(url): return "Could not read \(url.lastPathComponent)."
            case let .encodeFailed(reason): return "Could not compress the audio (\(reason))."
            }
        }
    }

    static func duration(ofWAV url: URL) -> TimeInterval {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
        let payload = max(0, size - PCMStreamWriter.headerBytes)
        return Double(payload) / (PCMStreamWriter.sampleRate * Double(PCMStreamWriter.bytesPerFrame))
    }

    /// Splits `url` into overlapping AAC chunks written into `directory`.
    static func chunk(wav url: URL, into directory: URL) throws -> [Chunk] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ChunkError.unreadable(url) }
        defer { try? handle.close() }

        let total = duration(ofWAV: url)
        guard total > 0.2 else { return [] }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let bytesPerSecond = PCMStreamWriter.sampleRate * Double(PCMStreamWriter.bytesPerFrame)
        var chunks: [Chunk] = []
        var offset: TimeInterval = 0
        var index = 0

        while offset < total {
            let end = min(total, offset + chunkSeconds)
            let byteStart = Int(offset * bytesPerSecond) + PCMStreamWriter.headerBytes
            let byteCount = Int((end - offset) * bytesPerSecond)

            try? handle.seek(toOffset: UInt64(byteStart))
            guard let pcm = try? handle.read(upToCount: byteCount), !pcm.isEmpty else { break }

            let name = "\(url.deletingPathExtension().lastPathComponent)-\(index).m4a"
            let destination = directory.appendingPathComponent(name)
            let silent = peak(ofInt16: pcm) < silenceThreshold

            if !silent {
                try encode(pcm: pcm, to: destination)
            }
            chunks.append(
                Chunk(
                    offset: offset,
                    duration: Double(pcm.count) / bytesPerSecond,
                    url: destination,
                    isSilent: silent
                )
            )

            index += 1
            if end >= total { break }
            offset = end - overlapSeconds
        }

        Diagnostics.log(
            "chunked \(url.lastPathComponent) total=\(Int(total))s into \(chunks.count) "
            + "(\(chunks.filter(\.isSilent).count) silent)"
        )
        return chunks
    }

    /// Raw 16-bit mono PCM at 16 kHz → AAC in an MP4 container.
    ///
    /// `audio/m4a` is on the transcribe API's accepted list, so the container needs no
    /// unwrapping. AAC at 32 kbps is transparent enough for speech that transcription
    /// quality is unaffected, and it is roughly a tenth the size of the PCM it came from.
    static func encode(pcm: Data, to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: PCMStreamWriter.sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw ChunkError.encodeFailed("no source format") }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: PCMStreamWriter.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]

        try? FileManager.default.removeItem(at: url)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            throw ChunkError.encodeFailed("\(error)")
        }

        let frameCount = pcm.count / PCMStreamWriter.bytesPerFrame
        let batch = 8192
        var written = 0

        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            while written < frameCount {
                let count = min(batch, frameCount - written)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(count)
                ), let channel = buffer.floatChannelData?[0] else { break }

                for index in 0..<count {
                    channel[index] = Float(samples[written + index]) / 32767
                }
                buffer.frameLength = AVAudioFrameCount(count)
                try? file.write(from: buffer)
                written += count
            }
        }
    }

    static func peak(ofInt16 pcm: Data) -> Float {
        pcm.withUnsafeBytes { raw -> Float in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            // Peak, not RMS: a quiet chunk with one clear sentence in it must not be
            // averaged down into "silence" and skipped.
            var loudest: Int16 = 0
            // Every 8th sample is plenty to decide "did anything happen here" and keeps
            // this from walking 38 MB per chunk.
            for index in stride(from: 0, to: samples.count, by: 8) {
                loudest = max(loudest, abs(samples[index] == Int16.min ? 0 : samples[index]))
            }
            return Float(loudest) / 32767
        }
    }
}
