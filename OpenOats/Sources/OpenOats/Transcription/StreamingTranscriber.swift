@preconcurrency import AVFoundation
import FluidAudio
import os

/// Consumes an audio buffer stream, detects speech via Silero VAD,
/// and transcribes completed speech segments via the TranscriptionBackend protocol.
final class StreamingTranscriber: @unchecked Sendable {
    private let backend: any TranscriptionBackend
    private let locale: Locale
    private let vadManager: VadManager
    private let speaker: Speaker
    private let onPartial: @Sendable (String) -> Void
    private let onFinal: @Sendable (String) -> Void
    private let log = Logger(subsystem: "com.openoats", category: "StreamingTranscriber")

    /// Optional echo gate: provides the current audio level of the other side.
    /// When set, mic speech segments are suppressed if the other side is actively
    /// playing audio (i.e. the mic is picking up speaker echo, not the user's voice).
    private let echoGateLevel: AudioLevel?
    /// System audio level above this threshold means the other side is speaking.
    private static let echoGateThreshold: Float = 0.02

    /// Resampler from source format to 16kHz mono Float32.
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    /// Cap concurrent transcription tasks to avoid unbounded memory growth
    /// when audio segments arrive faster than the model can transcribe.
    private static let maxConcurrentTranscriptions = 3

    init(
        backend: any TranscriptionBackend,
        locale: Locale,
        vadManager: VadManager,
        speaker: Speaker,
        echoGateLevel: AudioLevel? = nil,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String) -> Void
    ) {
        self.backend = backend
        self.locale = locale
        self.vadManager = vadManager
        self.speaker = speaker
        self.echoGateLevel = echoGateLevel
        self.onPartial = onPartial
        self.onFinal = onFinal
    }

    /// Silero VAD expects chunks of 4096 samples (256ms at 16kHz).
    private static let vadChunkSize = 4096
    private static let minimumSpeechSamples = 8000
    private static let prerollChunkCount = 2
    /// Flush speech for transcription every ~3 seconds (48,000 samples at 16kHz).
    private static let flushInterval = 48_000

    /// Main loop: reads audio buffers, runs VAD, transcribes speech segments.
    func run(stream: AsyncStream<AVAudioPCMBuffer>) async {
        var vadState = await vadManager.makeStreamState()
        var speechSamples: [Float] = []
        var vadBuffer: [Float] = []
        var recentChunks: [[Float]] = []
        var isSpeaking = false
        var bufferCount = 0

        // Echo gate: count how many VAD chunks had high system audio during this speech segment
        var echoActiveChunks = 0
        var totalSpeechChunks = 0

        // Track in-flight transcription tasks so we don't spawn unboundedly
        var inFlightTasks: [Task<Void, Never>] = []

        for await buffer in stream {
            bufferCount += 1
            if bufferCount <= 3 {
                let fmt = buffer.format
                diagLog("[\(speaker.rawValue)] buffer #\(bufferCount): frames=\(buffer.frameLength) sr=\(fmt.sampleRate) ch=\(fmt.channelCount) interleaved=\(fmt.isInterleaved) common=\(fmt.commonFormat.rawValue)")
            }

            guard let samples = extractSamples(buffer) else { continue }

            if bufferCount <= 3 {
                let maxVal = samples.max() ?? 0
                diagLog("[\(speaker.rawValue)] samples: count=\(samples.count) max=\(maxVal)")
            }

            vadBuffer.append(contentsOf: samples)

            while vadBuffer.count >= Self.vadChunkSize {
                let chunk = Array(vadBuffer.prefix(Self.vadChunkSize))
                vadBuffer.removeFirst(Self.vadChunkSize)
                let wasSpeaking = isSpeaking

                var startedSpeech = false
                var endedSpeech = false
                do {
                    let result = try await vadManager.processStreamingChunk(
                        chunk,
                        state: vadState,
                        config: .default,
                        returnSeconds: true,
                        timeResolution: 2
                    )
                    vadState = result.state

                    if let event = result.event {
                        switch event.kind {
                        case .speechStart:
                            if !wasSpeaking {
                                isSpeaking = true
                                startedSpeech = true
                                speechSamples = recentChunks.suffix(Self.prerollChunkCount).flatMap { $0 }
                                diagLog("[\(self.speaker.rawValue)] speech start")
                            }

                        case .speechEnd:
                            endedSpeech = wasSpeaking || isSpeaking
                        }
                    }

                    if wasSpeaking || startedSpeech || endedSpeech {
                        speechSamples.append(contentsOf: chunk)
                        recentChunks.removeAll(keepingCapacity: true)

                        // Sample the echo gate during speech
                        if let echoLevel = echoGateLevel {
                            totalSpeechChunks += 1
                            if echoLevel.value >= Self.echoGateThreshold {
                                echoActiveChunks += 1
                            }
                        }
                    } else {
                        recentChunks.append(chunk)
                        if recentChunks.count > Self.prerollChunkCount {
                            recentChunks.removeFirst(recentChunks.count - Self.prerollChunkCount)
                        }
                    }

                    if endedSpeech {
                        isSpeaking = false
                        diagLog("[\(self.speaker.rawValue)] speech end, samples=\(speechSamples.count)")

                        // Echo gate: if more than half the speech overlapped with
                        // active system audio, it's likely speaker echo — discard it.
                        let isEcho = totalSpeechChunks > 0
                            && Double(echoActiveChunks) / Double(totalSpeechChunks) > 0.5
                        echoActiveChunks = 0
                        totalSpeechChunks = 0

                        if isEcho {
                            diagLog("[\(self.speaker.rawValue)] echo gate: suppressed segment (echo ratio \(echoActiveChunks)/\(totalSpeechChunks))")
                            speechSamples.removeAll(keepingCapacity: true)
                        } else if speechSamples.count > Self.minimumSpeechSamples {
                            let segment = speechSamples
                            speechSamples.removeAll(keepingCapacity: true)
                            // Prune completed tasks
                            inFlightTasks.removeAll { $0.isCancelled }
                            // If at capacity, wait for the oldest task to finish
                            if inFlightTasks.count >= Self.maxConcurrentTranscriptions {
                                await inFlightTasks.removeFirst().value
                            }
                            let task = Task { [self] in
                                await self.transcribeSegment(segment)
                            }
                            inFlightTasks.append(task)
                        } else {
                            speechSamples.removeAll(keepingCapacity: true)
                        }
                    } else if isSpeaking {

                        // Flush every ~3s for near-real-time output during continuous speech
                        if speechSamples.count >= Self.flushInterval {
                            // Check echo gate on flush too
                            let isEcho = totalSpeechChunks > 0
                                && Double(echoActiveChunks) / Double(totalSpeechChunks) > 0.5

                            if isEcho {
                                diagLog("[\(self.speaker.rawValue)] echo gate: suppressed flush segment")
                                speechSamples.removeAll(keepingCapacity: true)
                            } else {
                                let segment = speechSamples
                                speechSamples.removeAll(keepingCapacity: true)
                                inFlightTasks.removeAll { $0.isCancelled }
                                if inFlightTasks.count >= Self.maxConcurrentTranscriptions {
                                    await inFlightTasks.removeFirst().value
                                }
                                let task = Task { [self] in
                                    await self.transcribeSegment(segment)
                                }
                                inFlightTasks.append(task)
                            }
                            echoActiveChunks = 0
                            totalSpeechChunks = 0
                        }
                    }
                } catch {
                    log.error("VAD error: \(error.localizedDescription)")
                }
            }
        }

        // Transcribe any remaining speech
        if speechSamples.count > Self.minimumSpeechSamples {
            let task = Task { [self] in
                await self.transcribeSegment(speechSamples)
            }
            inFlightTasks.append(task)
        }

        // Wait for all in-flight transcriptions to complete before exiting
        for task in inFlightTasks {
            await task.value
        }
    }

    private func transcribeSegment(_ samples: [Float]) async {
        do {
            let text = try await backend.transcribe(samples, locale: locale)
            guard !text.isEmpty else { return }
            log.info("[\(self.speaker.rawValue)] transcribed: \(text.prefix(80))")
            onFinal(text)
        } catch {
            log.error("ASR error: \(error.localizedDescription)")
        }
    }

    /// Extract [Float] samples from an AVAudioPCMBuffer, resampling if needed.
    private func extractSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let sourceFormat = buffer.format
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        // Fast path: already Float32 at 16kHz (common for system audio capture)
        if sourceFormat.commonFormat == .pcmFormatFloat32 && sourceFormat.sampleRate == 16000 {
            guard let channelData = buffer.floatChannelData else { return nil }
            if sourceFormat.channelCount == 1 {
                // Mono — direct copy
                return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            } else {
                // Multi-channel — take first channel only
                return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            }
        }

        // Downmix multi-channel to mono before resampling
        // (AVAudioConverter mishandles deinterleaved multi-channel input)
        var inputBuffer = buffer
        if sourceFormat.channelCount > 1, let src = buffer.floatChannelData {
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceFormat.sampleRate,
                channels: 1,
                interleaved: false
            )!
            if let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity),
               let dst = monoBuf.floatChannelData?[0] {
                monoBuf.frameLength = buffer.frameLength
                let channels = Int(sourceFormat.channelCount)
                let scale = 1.0 / Float(channels)
                for i in 0..<frameLength {
                    var sum: Float = 0
                    for ch in 0..<channels { sum += src[ch][i] }
                    dst[i] = sum * scale
                }
                inputBuffer = monoBuf
            }
        }

        // Slow path: need to resample via AVAudioConverter
        let inputFormat = inputBuffer.format
        if converter == nil || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)
        guard outputFrames > 0 else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrames
        ) else { return nil }

        var error: NSError?
        nonisolated(unsafe) var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let error {
            log.error("Resample error: \(error.localizedDescription)")
            return nil
        }

        guard let channelData = outputBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(outputBuffer.frameLength)
        ))
    }
}
