@preconcurrency import AVFoundation
import Foundation

/// Captures normalized Float32 mono PCM, resampled to Whisper's 16 kHz.
/// No cumulative recording is retained by the capture layer.
@MainActor
final class MicrophoneStream {
    private let engine = AVAudioEngine()
    private var continuation: AsyncThrowingStream<[Float], Error>.Continuation?
    private var levelContinuation: AsyncStream<Float>.Continuation?
    private var hasTap = false
    private let sessionQueue = DispatchQueue(label: "de.serbskilud.sorbfisch.audio-session")
    private var sessionRequested = false
    private var generation = 0

    func start() async throws -> (audio: AsyncThrowingStream<[Float], Error>, levels: AsyncStream<Float>) {
        generation += 1
        let requestedGeneration = generation
        sessionRequested = true
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sessionQueue.async {
                    do {
                        let session = AVAudioSession.sharedInstance()
                        try session.setCategory(.record, mode: .measurement, options: [])
                        try session.setActive(true)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
            guard generation == requestedGeneration else { throw CancellationError() }
            return try startCapture()
        } catch {
            if generation == requestedGeneration { stop() }
            throw error
        }
    }

    private func startCapture() throws -> (audio: AsyncThrowingStream<[Float], Error>, levels: AsyncStream<Float>) {
        let input = engine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0,
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                channels: 1, interleaved: false
              ),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw CaptureError.invalidFormat
        }

        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(
            bufferingPolicy: .bufferingOldest(320)
        )
        self.continuation = continuation
        let (levels, levelContinuation) = AsyncStream<Float>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.levelContinuation = levelContinuation
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(sourceFormat.sampleRate / 10),
                         format: sourceFormat) { buffer, _ in
            do {
                let samples = try Self.convert(buffer, using: converter, to: targetFormat)
                if !samples.isEmpty {
                    let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
                    levelContinuation.yield(Float(min(rms * 12, 1)))
                }
                if case .dropped = continuation.yield(samples) {
                    continuation.finish(throwing: CaptureError.backlogExceeded)
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
        hasTap = true
        engine.prepare()
        try engine.start()
        return (stream, levels)
    }

    func stop() {
        generation += 1
        engine.stop()
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        continuation?.finish()
        continuation = nil
        levelContinuation?.finish()
        levelContinuation = nil
        guard sessionRequested else { return }
        sessionRequested = false
        sessionQueue.async {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                // Best-effort teardown must not block the UI or restart capture.
                NSLog("Audio session deactivation failed: %@", error.localizedDescription)
            }
        }
    }

    nonisolated private static func convert(
        _ input: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat
    ) throws -> [Float] {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw CaptureError.invalidFormat
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard status != .error, let channel = output.floatChannelData?[0] else {
            throw CaptureError.invalidFormat
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

private enum CaptureError: LocalizedError {
    case invalidFormat, backlogExceeded
    var errorDescription: String? {
        switch self {
        case .invalidFormat: "Das Mikrofonformat konnte nicht verarbeitet werden."
        case .backlogExceeded: "Die Spracherkennung kann mit der Aufnahme nicht Schritt halten. Bitte starte eine neue Aufnahme."
        }
    }
}
