@preconcurrency import AVFoundation
import FluidAudio
import os

/// Transcribes an audio file offline by reading it, running VAD, and transcribing each speech segment.
final class AudioFileTranscriber: @unchecked Sendable {
    private let backend: any TranscriptionBackend
    private let locale: Locale
    private let log = Logger(subsystem: "com.openoats", category: "AudioFileTranscriber")

    /// VAD chunk size matching StreamingTranscriber (4096 samples = 256ms at 16kHz).
    private static let vadChunkSize = 4096
    private static let minimumSpeechSamples = 8000
    private static let prerollChunkCount = 2
    private static let targetSampleRate: Double = 16000

    init(backend: any TranscriptionBackend, locale: Locale) {
        self.backend = backend
        self.locale = locale
    }

    struct TranscriptionResult: Sendable {
        let records: [SessionRecord]
        let duration: TimeInterval
    }

    /// Transcribe an audio file, reporting progress via callback.
    /// - Parameters:
    ///   - url: Path to the audio file (.m4a, .wav, .mp3, etc.)
    ///   - onProgress: Called with (completedSegments, totalSegments) as transcription progresses.
    /// - Returns: Array of SessionRecords with timestamps derived from audio position.
    func transcribe(
        url: URL,
        onProgress: @Sendable @escaping (Int, Int) -> Void
    ) async throws -> TranscriptionResult {
        let samples = try readAudioFile(url: url)
        guard !samples.isEmpty else {
            throw AudioFileTranscriberError.emptyAudioFile
        }

        let fileDuration = Double(samples.count) / Self.targetSampleRate

        // Run VAD to find speech segments
        let segments = try await detectSpeechSegments(samples: samples)
        guard !segments.isEmpty else {
            throw AudioFileTranscriberError.noSpeechDetected
        }

        log.info("Found \(segments.count) speech segments in \(String(format: "%.1f", fileDuration))s audio")

        // Transcribe each segment
        var records: [SessionRecord] = []
        let fileStartDate = Date()

        for (index, segment) in segments.enumerated() {
            onProgress(index, segments.count)

            let text = try await backend.transcribe(segment.samples, locale: locale)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let offsetSeconds = Double(segment.startSample) / Self.targetSampleRate
            let timestamp = fileStartDate.addingTimeInterval(offsetSeconds)

            let record = SessionRecord(
                speaker: .you,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                timestamp: timestamp
            )
            records.append(record)
        }

        onProgress(segments.count, segments.count)
        return TranscriptionResult(records: records, duration: fileDuration)
    }

    // MARK: - Audio File Reading

    private func readAudioFile(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { return [] }

        let srcFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

        guard let readBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            throw AudioFileTranscriberError.readFailed
        }
        try file.read(into: readBuf)

        // Target: 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioFileTranscriberError.readFailed
        }

        // Already at target format
        if srcFormat.sampleRate == Self.targetSampleRate && srcFormat.channelCount == 1
            && srcFormat.commonFormat == .pcmFormatFloat32 {
            return Self.extractSamples(from: readBuf)
        }

        // Resample via AVAudioConverter
        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            throw AudioFileTranscriberError.readFailed
        }

        let ratio = Self.targetSampleRate / srcFormat.sampleRate
        let outFrames = AVAudioFrameCount(Double(frameCount) * ratio) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else {
            throw AudioFileTranscriberError.readFailed
        }

        var consumed = false
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return readBuf
        }

        if let convError {
            throw convError
        }

        return Self.extractSamples(from: outBuf)
    }

    private static func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength)
        guard count > 0, let data = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: count))
    }

    // MARK: - VAD Segmentation

    private struct SpeechSegment {
        let startSample: Int
        let samples: [Float]
    }

    private func detectSpeechSegments(samples: [Float]) async throws -> [SpeechSegment] {
        let vadManager = try await VadManager()
        var vadState = await vadManager.makeStreamState()

        var segments: [SpeechSegment] = []
        var speechSamples: [Float] = []
        var speechStartSample = 0
        var isSpeaking = false
        var recentChunks: [(offset: Int, data: [Float])] = []
        var offset = 0

        while offset + Self.vadChunkSize <= samples.count {
            let chunk = Array(samples[offset..<(offset + Self.vadChunkSize)])
            let wasSpeaking = isSpeaking

            let result = try await vadManager.processStreamingChunk(
                chunk,
                state: vadState,
                config: .default,
                returnSeconds: true,
                timeResolution: 2
            )
            vadState = result.state

            var startedSpeech = false
            var endedSpeech = false

            if let event = result.event {
                switch event.kind {
                case .speechStart:
                    if !wasSpeaking {
                        isSpeaking = true
                        startedSpeech = true
                        let preroll = recentChunks.suffix(Self.prerollChunkCount)
                        speechStartSample = preroll.first?.offset ?? offset
                        speechSamples = preroll.flatMap { $0.data }
                    }
                case .speechEnd:
                    endedSpeech = wasSpeaking || isSpeaking
                }
            }

            if wasSpeaking || startedSpeech || endedSpeech {
                speechSamples.append(contentsOf: chunk)
                recentChunks.removeAll(keepingCapacity: true)
            } else {
                recentChunks.append((offset: offset, data: chunk))
                if recentChunks.count > Self.prerollChunkCount {
                    recentChunks.removeFirst(recentChunks.count - Self.prerollChunkCount)
                }
            }

            if endedSpeech {
                isSpeaking = false
                if speechSamples.count > Self.minimumSpeechSamples {
                    segments.append(SpeechSegment(startSample: speechStartSample, samples: speechSamples))
                }
                speechSamples.removeAll(keepingCapacity: true)
            }

            offset += Self.vadChunkSize
        }

        // Flush remaining speech
        if isSpeaking && speechSamples.count > Self.minimumSpeechSamples {
            segments.append(SpeechSegment(startSample: speechStartSample, samples: speechSamples))
        }

        return segments
    }

    enum AudioFileTranscriberError: LocalizedError {
        case emptyAudioFile
        case noSpeechDetected
        case readFailed

        var errorDescription: String? {
            switch self {
            case .emptyAudioFile: "The audio file is empty."
            case .noSpeechDetected: "No speech was detected in the audio file."
            case .readFailed: "Failed to read the audio file."
            }
        }
    }
}
