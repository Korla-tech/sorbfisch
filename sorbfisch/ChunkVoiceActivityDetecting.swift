import CoreML
import FluidAudio
import Foundation
import OSLog

actor SileroChunkVAD {
    static let speechThreshold: Float = 0.5
    private let manager: VadManager
    private var state = VadStreamState.initial()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "de.serbskilud.sorbfisch",
        category: "SileroVAD"
    )

    private init(model: MLModel) {
        manager = VadManager(
            config: VadConfig(defaultThreshold: Self.speechThreshold),
            vadModel: model
        )
    }

    static func bundled() async throws -> SileroChunkVAD {
        guard let url = Bundle.main.url(
            forResource: "silero-vad-unified-256ms-v6.2.1",
            withExtension: "mlmodelc"
        ) else {
            throw ModelError.missing
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let model = try await MLModel.load(contentsOf: url, configuration: configuration)
        return SileroChunkVAD(model: model)
    }

    func reset() {
        state = .initial()
    }

    func isSpeech(_ frame: [Float]) async throws -> Bool {
        // Only real 256 ms frames: no padding/truncation of microphone chunks.
        precondition(frame.count == VADAudioFrames.frameSize)
        try Task.checkCancellation()
        let start = ContinuousClock.now
        let result = try await manager.processStreamingChunk(frame, state: state)
        state = result.state
        let speech = result.probability >= Self.speechThreshold
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        logger.debug("Silero: probability=\(result.probability, format: .fixed(precision: 3)), speech=\(speech), inference=\(seconds * 1000, format: .fixed(precision: 2)) ms, RTF=\(0.256 / seconds, format: .fixed(precision: 3))")
        return speech
    }

    private enum ModelError: LocalizedError {
        case missing
        var errorDescription: String? {
            "Das gebündelte Silero-VAD-Modell konnte nicht gefunden werden."
        }
    }
}
