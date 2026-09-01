import AVFoundation
import Foundation

/// Writes one capture stream to a 16 kHz mono 16-bit WAV, safely, for as long as a
/// meeting lasts.
///
/// Three things this does that a dictation app never had to care about:
///
/// **Nothing touches the disk on the audio thread.** QuickTalk called
/// `AVAudioFile.write(from:)` straight from the render callback, which is fine for a
/// fifteen-second dictation and wrong for an hour. `write` can allocate and can block on
/// I/O, and a blocked render callback is a dropped buffer — a hole in the recording. Here
/// the callback only converts to Int16 and appends to a byte accumulator; a timer on a
/// background queue drains it to a `FileHandle` four times a second.
///
/// **The header is written first and patched last.** A WAV is a 44-byte header whose
/// length fields cannot be known until the recording ends. Writing the header up front
/// with placeholder lengths means a recording interrupted by a crash or a power loss is
/// still a file with valid PCM in it — `repair(at:)` patches the lengths from the file's
/// actual size on the next launch. Losing an hour of someone else's meeting because the
/// app quit before it could finalise a container is not acceptable.
///
/// **Raw PCM, not AAC.** Compression happens later, per chunk, at upload time. A
/// truncated AAC file with no finalised `moov` atom is unreadable; truncated PCM is just
/// a shorter recording.
final class PCMStreamWriter {
    /// 16 kHz mono is plenty for speech, and it is what the chunker's byte arithmetic
    /// assumes — one second is exactly `sampleRate * 2` bytes.
    static let sampleRate: Double = 16_000
    static let bytesPerFrame = 2
    static let headerBytes = 44

    let url: URL

    /// 0…1, already smoothed for display.
    var onLevel: ((Float) -> Void)?

    /// Loudest sample seen so far. A peak near zero means the capture failed, not the API.
    private(set) var peakLevel: Float = 0

    private let handle: FileHandle
    private let drainQueue = DispatchQueue(label: "com.quickmeet.QuickMeet.writer")
    private var timer: DispatchSourceTimer?

    /// Guards `pending` only. Held for the length of an append or a swap — microseconds,
    /// and never across I/O, which is what keeps it acceptable to take on the audio thread.
    private let lock = NSLock()
    private var pending = Data()
    /// Silence owed to the timeline, in seconds — see `padSilence(seconds:)`.
    private var pendingSilence: TimeInterval = 0
    private var closed = false

    private var smoothedLevel: Float = 0
    private(set) var byteCount: Int = 0

    /// Downmix scratch, allocated once. The render callback must not allocate.
    private var monoScratch: [Float]
    private var int16Scratch: [Int16]
    private let converter: AVAudioConverter?
    private let sourceFormat: AVAudioFormat
    private let monoSourceFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var convertBuffer: AVAudioPCMBuffer?
    private var monoBuffer: AVAudioPCMBuffer?

    enum WriterError: Error {
        case couldNotCreateFile
        case unsupportedFormat
    }

    /// - Parameter sourceFormat: whatever the hardware or the tap actually hands over.
    ///   Read it *after* the device is bound — a different device can mean a different
    ///   sample rate and channel count.
    init(url: URL, sourceFormat: AVAudioFormat, maxFrames: AVAudioFrameCount = 4096) throws {
        self.url = url
        self.sourceFormat = sourceFormat

        guard let monoSource = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw WriterError.unsupportedFormat }

        self.monoSourceFormat = monoSource
        self.outputFormat = output

        // Channels are collapsed by hand before this converter sees anything, so it only
        // ever does rate conversion. AVAudioConverter's own multichannel-to-mono mapping
        // is underspecified — for a stereo tap it is the difference between "both voices"
        // and "whatever happened to be in the left channel".
        self.converter = sourceFormat.sampleRate == Self.sampleRate
            ? nil
            : AVAudioConverter(from: monoSource, to: output)

        let capacity = Int(maxFrames) * 4
        self.monoScratch = [Float](repeating: 0, count: capacity)
        self.int16Scratch = [Int16](repeating: 0, count: capacity * 4)
        self.monoBuffer = AVAudioPCMBuffer(pcmFormat: monoSource, frameCapacity: AVAudioFrameCount(capacity))

        let ratio = Self.sampleRate / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(capacity) * ratio) + 1024
        self.convertBuffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: outCapacity)

        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard manager.createFile(atPath: url.path, contents: Self.header(dataBytes: 0)) else {
            throw WriterError.couldNotCreateFile
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw WriterError.couldNotCreateFile
        }
        self.handle = handle
        _ = try? handle.seekToEnd()

        startDraining()
    }

    // MARK: - Capture side

    /// Called from the real-time audio thread. Allocates nothing.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0, frames <= monoScratch.count else { return }

        let channelCount = Int(buffer.format.channelCount)

        // Collapse to mono by averaging. For a stereo system-audio tap this is what keeps
        // a participant panned to one side from vanishing.
        if channelCount == 1 {
            memcpy(&monoScratch, channels[0], frames * MemoryLayout<Float>.size)
        } else {
            let scale = 1 / Float(channelCount)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channelCount { sum += channels[channel][frame] }
                monoScratch[frame] = sum * scale
            }
        }

        var level: Float = 0
        for frame in 0..<frames { level += monoScratch[frame] * monoScratch[frame] }
        level = (level / Float(frames)).squareRoot()
        peakLevel = max(peakLevel, level)
        report(level: level)

        let outputCount: Int
        // Filled below from whichever source applies, inside a scope where its storage is
        // guaranteed alive — taking an UnsafePointer to `monoScratch` and using it after
        // the expression would be a dangling read.
        if let converter, let monoBuffer, let convertBuffer {
            monoBuffer.frameLength = AVAudioFrameCount(frames)
            memcpy(monoBuffer.floatChannelData![0], monoScratch, frames * MemoryLayout<Float>.size)

            var consumed = false
            var error: NSError?
            convertBuffer.frameLength = 0
            converter.convert(to: convertBuffer, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return monoBuffer
            }
            guard error == nil, convertBuffer.frameLength > 0 else { return }
            outputCount = Int(convertBuffer.frameLength)
            guard outputCount <= int16Scratch.count else { return }
            let samples = convertBuffer.floatChannelData![0]
            for index in 0..<outputCount {
                int16Scratch[index] = Int16(max(-1, min(1, samples[index])) * 32767)
            }
        } else {
            outputCount = frames
            guard outputCount <= int16Scratch.count else { return }
            for index in 0..<outputCount {
                int16Scratch[index] = Int16(max(-1, min(1, monoScratch[index])) * 32767)
            }
        }

        int16Scratch.withUnsafeBufferPointer { pointer in
            let bytes = UnsafeRawBufferPointer(
                start: pointer.baseAddress, count: outputCount * Self.bytesPerFrame
            )
            lock.lock()
            pending.append(contentsOf: bytes)
            lock.unlock()
        }
    }

    /// Records that `seconds` of wall-clock time passed with no audio delivered, so the
    /// file keeps its place on the clock.
    ///
    /// A capture device does not always run. An aggregate anchored to a Bluetooth output
    /// stops clocking entirely while nothing is playing — measured — so the IOProc simply
    /// is not called. Without this the file would be *shorter* than the meeting: the
    /// silence would be squeezed out, every later timestamp would slide earlier, and the
    /// system stream would interleave against the microphone's turns at the wrong points.
    /// A transcript that puts an answer before its question is worse than one with a gap.
    ///
    /// Called from the audio thread, so it only moves a counter; the zeros are produced on
    /// the drain queue.
    func padSilence(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        lock.lock()
        pendingSilence += seconds
        lock.unlock()
    }

    private func report(level: Float) {
        // Attack fast, release slower — a meter that snaps up on a syllable and falls
        // back smoothly, rather than flickering.
        smoothedLevel = level > smoothedLevel
            ? smoothedLevel + (level - smoothedLevel) * 0.75
            : smoothedLevel + (level - smoothedLevel) * 0.20

        let value = Self.normalized(smoothedLevel)
        DispatchQueue.main.async { [onLevel] in onLevel?(value) }
    }

    /// Maps raw RMS onto 0…1 the way a meter should: on a decibel scale.
    ///
    /// Linear RMS is why normal speech barely moves a meter — conversational level sits
    /// around 0.02–0.05 RMS, near the floor linearly. Human loudness is logarithmic, so
    /// map dBFS and lift the quiet end with a curve.
    static func normalized(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let clamped = min(max(db, -50), -8)
        return pow((clamped + 50) / 42, 0.65)
    }

    // MARK: - Drain side

    private func startDraining() {
        let timer = DispatchSource.makeTimerSource(queue: drainQueue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    private func drain() {
        lock.lock()
        let chunk = pending
        pending.removeAll(keepingCapacity: true)
        let silence = pendingSilence
        pendingSilence = 0
        lock.unlock()

        // Silence first: it represents time that passed *before* whatever is in `chunk`.
        if silence > 0 {
            let frames = Int(silence * Self.sampleRate)
            let bytes = frames * Self.bytesPerFrame
            if bytes > 0 {
                do {
                    // Written in slices so a long gap never asks for one huge allocation.
                    let slice = Data(count: min(bytes, 64 * 1024))
                    var written = 0
                    while written < bytes {
                        let count = min(slice.count, bytes - written)
                        try handle.write(contentsOf: slice.prefix(count))
                        written += count
                    }
                    byteCount += bytes
                    Diagnostics.log("writer padded \(String(format: "%.2f", silence))s of silence to keep the timeline")
                } catch {
                    Diagnostics.recordError("writer could not pad silence: \(error)")
                }
            }
        }

        guard !chunk.isEmpty else { return }
        do {
            try handle.write(contentsOf: chunk)
            byteCount += chunk.count
        } catch {
            Diagnostics.recordError("writer could not append \(chunk.count) bytes: \(error)")
        }
    }

    /// Flushes, patches the header, and returns the finished file.
    @discardableResult
    func close() -> URL {
        guard !closed else { return url }
        closed = true

        timer?.cancel()
        timer = nil
        drainQueue.sync { self.drain() }

        let dataBytes = byteCount
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: Self.header(dataBytes: dataBytes))
        try? handle.close()

        Diagnostics.log(
            "writer closed \(url.lastPathComponent) bytes=\(dataBytes) "
            + "seconds=\(String(format: "%.1f", Double(dataBytes) / (Self.sampleRate * 2))) "
            + "peak=\(String(format: "%.4f", peakLevel))"
        )
        return url
    }

    var duration: TimeInterval {
        Double(byteCount) / (Self.sampleRate * Double(Self.bytesPerFrame))
    }

    // MARK: - WAV header

    static func header(dataBytes: Int) -> Data {
        var data = Data(capacity: headerBytes)
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        let rate = UInt32(sampleRate)
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(16)                                    // PCM chunk size
        append16(1)                                     // format: PCM
        append16(1)                                     // channels
        append32(rate)
        append32(rate * UInt32(bytesPerFrame))          // byte rate
        append16(UInt16(bytesPerFrame))                 // block align
        append16(16)                                    // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataBytes))
        return data
    }

    /// Patches a WAV whose lengths were never written — the file a crash leaves behind.
    /// Returns true when it actually repaired something.
    @discardableResult
    static func repair(at url: URL) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size > headerBytes,
              let handle = try? FileHandle(forUpdating: url)
        else { return false }
        defer { try? handle.close() }

        try? handle.seek(toOffset: 40)
        let declared = (try? handle.read(upToCount: 4)).flatMap { data -> UInt32? in
            guard data.count == 4 else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        } ?? 0

        let actual = size - headerBytes
        guard Int(declared) != actual else { return false }

        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: header(dataBytes: actual))
        Diagnostics.log("repaired truncated WAV \(url.lastPathComponent): \(declared) → \(actual) bytes")
        return true
    }
}
