import Combine
import Foundation
import OSLog
import SwiftUI
import UIKit
import WhisperKit

@MainActor
final class LiveTranslationViewModel: ObservableObject {
    enum ModelState {
        case idle
        case loading
        case unloading
        case ready
        case failed
    }

    @Published private(set) var modelState: ModelState = .idle
    @Published private(set) var outputLanguage: OutputLanguage = .german
    @Published private(set) var isPrewarming = false
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var isRecording = false
    @Published private(set) var translatedText = ""
    @Published private(set) var confidence: Double?
    @Published private(set) var audioLevels: [Float] = []
    @Published private(set) var didCopy = false
    @Published var isShowingError = false
    @Published private(set) var errorMessage: String?

    private var whisperKit: WhisperKit?
    private let microphone = MicrophoneStream()
    private var vad: SileroChunkVAD?
    private var recordingTask: Task<Void, Never>?
    private var meteringTask: Task<Void, Never>?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "de.serbskilud.sorbfisch",
        category: "WhisperKit"
    )
    private var modelLoadStartedAt: Date?
    private var recordingStartedAt: Date?
    private var submittedSampleCount = 0
    private var completedDecodeCount = 0
    private var sessionID = UUID()
    private var isStartingRecording = false
    private var decodingOptions: DecodingOptions?
    private var downloadID: UUID?

    var canRecord: Bool {
        modelState != .loading && modelState != .unloading
            && !isStartingRecording && (isRecording || recordingTask == nil)
    }

    var canChangeOutputLanguage: Bool {
        modelState != .loading && modelState != .unloading
            && !isRecording && !isStartingRecording && recordingTask == nil
    }

    func selectOutputLanguage(_ language: OutputLanguage) async {
        guard canChangeOutputLanguage, outputLanguage != language else { return }
        outputLanguage = language
        translatedText = ""
        confidence = nil
        audioLevels = []
        didCopy = false
        await unloadModel()
    }

    var emptyStateMessage: String {
        if modelState == .unloading {
            return "Das bisherige Sprachmodell wird entladen …"
        }
        if modelState == .loading {
            if isDownloading {
                return "Das Sprachmodell wird heruntergeladen …\nBeim ersten Mal ist eine Internetverbindung nötig."
            }
            return isPrewarming
                ? "Das Sprachmodell wird für dieses Gerät optimiert …\nDas kann beim ersten Start einige Minuten dauern."
                : "Das Sprachmodell wird geladen …"
        }
        if isRecording {
            return "Sprich jetzt (Whisper-Tiny-Testmodell)"
        }
        return "Tippe auf das Mikrofon und beginne zu sprechen."
    }

    var statusMessage: String {
        if isRecording {
            return "Hört zu und transkribiert (Testmodell) …"
        }
        if modelState == .unloading { return "Modell wird entladen …" }
        if modelState == .loading {
            if isDownloading { return "Modell wird heruntergeladen …" }
            return isPrewarming ? "Modell wird optimiert …" : "Modell wird geladen …"
        }
        if modelState == .failed { return "Modell nicht verfügbar" }
        if modelState == .idle { return "Modell noch nicht geladen" }
        if translatedText.isEmpty { return "Bereit" }
        return "Testtranskript abgeschlossen"
    }

    var statusSymbol: String {
        if isRecording { return "record.circle" }
        if modelState == .unloading { return "arrow.down.circle" }
        if modelState == .loading {
            return isPrewarming ? "speedometer" : "arrow.down.circle"
        }
        if modelState == .failed { return "exclamationmark.triangle" }
        if modelState == .idle { return "circle.dashed" }
        return "checkmark.circle"
    }

    var controlHint: String {
        switch modelState {
        case .idle:
            return "Tippe, um das Sprachmodell zu laden"
        case .loading:
            if isDownloading { return "Sprachmodell wird heruntergeladen" }
            return isPrewarming
                ? "Sprachmodell wird für dieses Gerät optimiert"
                : "Sprachmodell wird geladen"
        case .unloading:
            return "Sprachmodell wird entladen"
        case .failed:
            return "Tippe, um das Sprachmodell erneut zu laden"
        case .ready:
            return isRecording ? "Tippe zum Beenden" : "Tippe zum Sprechen"
        }
    }

    func prepareModel(forceRetry: Bool = false) async {
        guard modelState != .loading, modelState != .unloading,
              recordingTask == nil, !isStartingRecording,
              forceRetry || modelState == .idle else { return }

        if isRecording {
            stopRecording()
        }

        modelState = .loading
        isPrewarming = false
        isDownloading = false
        downloadProgress = 0
        defer {
            isPrewarming = false
            isDownloading = false
            downloadID = nil
        }
        errorMessage = nil
        modelLoadStartedAt = Date()

        do {
            // Release the old model before loading the other large model.
            if let previousKit = whisperKit {
                whisperKit = nil
                decodingOptions = nil
                await previousKit.unloadModels()
            }
            let localVAD: SileroChunkVAD
            if let vad { localVAD = vad }
            else { localVAD = try await SileroChunkVAD.bundled() }
            let cache = try RemoteModelCache.applicationCache()
            print("available memory: ", os_proc_available_memory())
            let variant = outputLanguage.modelResource
            let modelURL: URL
            if let cached = cache.completedModel(for: variant) {
                modelURL = cached
                logger.info("Using cached model: \(variant, privacy: .public)")
            } else {
                isDownloading = true
                let id = UUID()
                downloadID = id
                logger.info("Downloading \(variant, privacy: .public) from \(RemoteModelCache.repository, privacy: .public)")
                modelURL = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: cache.root,
                    from: RemoteModelCache.repository,
                    progressCallback: { [weak self] progress in
                        let fraction = min(max(progress.fractionCompleted, 0), 1)
                        Task { @MainActor [weak self] in
                            guard let self, self.downloadID == id, self.isDownloading else { return }
                            self.downloadProgress = max(self.downloadProgress, fraction)
                        }
                    }
                )
                try Task.checkCancellation()
                try cache.markComplete(modelURL, variant: variant)
                downloadProgress = 1
                isDownloading = false
                downloadID = nil
            }
            try Task.checkCancellation()
    
            let config = WhisperKitConfig(
                modelFolder: modelURL.path,
                tokenizerFolder: cache.root,
                verbose: true,
                prewarm: false,
                load: false,
                download: false
            )
            let kit = try await WhisperKit(config)
            isPrewarming = true
            try await kit.prewarmModels()
            isPrewarming = false
            try await kit.loadModels()
            print("Detected variant:", kit.modelVariant)

            guard kit.tokenizer != nil else {
                throw LiveTranslationError.tokenizerUnavailable
            }

            let options = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: nil,
                temperature: 0,
                usePrefillPrompt: true,
                detectLanguage: true,
                skipSpecialTokens: true,
                wordTimestamps: false,
            )

            whisperKit = kit
            vad = localVAD
            decodingOptions = options
            modelState = .ready
            logModelMetrics(kit)
        } catch is CancellationError {
            // SwiftUI can cancel preparation when this screen disappears.
            // Incomplete downloads remain retryable, without showing an alert.
            modelState = .idle
        } catch {
            modelState = .failed
            logger.error("Model preparation failed: \(error.localizedDescription, privacy: .public)")
            present(error: error)
        }
    }

    func toggleRecording() async {
        if isRecording {
            stopRecording()
            return
        }

        switch modelState {
        case .idle:
            await prepareModel()
        case .failed:
            await prepareModel(forceRetry: true)
        case .ready:
            await startRecording()
        case .loading, .unloading:
            break
        }
    }

    func stopRecording() {
        guard isRecording || isStartingRecording || recordingTask != nil else { return }
        isRecording = false
        sessionID = UUID()
        microphone.stop()
        meteringTask?.cancel()
        meteringTask = nil
        recordingTask?.cancel()
        logRecordingSummary()
    }

    func copyTranslation() {
        guard !translatedText.isEmpty else { return }
        UIPasteboard.general.string = translatedText
        didCopy = true

        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }

    private func startRecording() async {
        guard modelState == .ready, canRecord, recordingTask == nil, let kit = whisperKit,
              let options = decodingOptions, let vad else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }
        let id = UUID()
        sessionID = id

        let hasPermission = await AudioProcessor.requestRecordPermission()
        guard sessionID == id, !Task.isCancelled else { return }
        guard hasPermission else {
            present(error: LiveTranslationError.microphonePermissionDenied)
            return
        }

        do {
            await vad.reset()
            guard sessionID == id, !Task.isCancelled else { return }
            let streams = try await microphone.start()
            guard sessionID == id, !Task.isCancelled else {
                microphone.stop()
                return
            }
            translatedText = ""
            confidence = nil
            audioLevels = []
            submittedSampleCount = 0
            completedDecodeCount = 0
            recordingStartedAt = Date()
            isRecording = true
            meteringTask = Task { [weak self] in
                for await level in streams.levels {
                    guard !Task.isCancelled, let self,
                          self.sessionID == id, self.isRecording else { return }
                    self.audioLevels.append(level)
                    self.audioLevels = Array(self.audioLevels.suffix(80))
                }
            }

            recordingTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    microphone.stop()
                    meteringTask?.cancel()
                    meteringTask = nil
                    isRecording = false
                    recordingTask = nil
                    logRecordingSummary()
                }
                do {
                    try await runSequence(streams.audio, vad: vad, kit: kit, options: options, session: id)
                } catch is CancellationError {
                } catch {
                    if sessionID == id { present(error: error) }
                }
            }
        } catch is CancellationError {
        } catch {
            guard sessionID == id else { return }
            microphone.stop()
            present(error: error)
        }
    }

    private func unloadModel() async {
        let loadedKit = whisperKit
        whisperKit = nil
        decodingOptions = nil
        guard let loadedKit else {
            modelState = .idle
            return
        }

        modelState = .unloading
        await loadedKit.unloadModels()
        modelState = .idle
    }

    private func runSequence(
        _ stream: AsyncThrowingStream<[Float], Error>,
        vad: SileroChunkVAD, kit: WhisperKit, options: DecodingOptions, session id: UUID
    ) async throws {
        var buffer = SpeechSequenceBuffer()
        var frames = VADAudioFrames()
        for try await chunk in stream {
            try Task.checkCancellation()
            guard sessionID == id else { return }
            guard !chunk.isEmpty else { continue }

            for frame in frames.append(chunk) {
                let isSpeech = try await vad.isSpeech(frame)
                try Task.checkCancellation()
                guard sessionID == id else { return }
                let previousSize = buffer.samples.count
                let utterance = buffer.append(frame, isSpeech: isSpeech)
                if utterance == nil, buffer.samples.isEmpty, previousSize > 0 {
                    logger.debug("Silence-only buffer discarded")
                }
                guard let utterance else { continue }

                let startedAt = ContinuousClock.now
                let results = try await kit.transcribe(audioArray: utterance.samples, decodeOptions: options)
                let elapsed = startedAt.duration(to: .now)
                let wallSeconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                try Task.checkCancellation()
                guard sessionID == id else { return }

                let segments = results.flatMap(\.segments)
                let text = Self.removingSpecialTokens(from: results.map(\.text).joined(separator: " "))
                if !text.isEmpty {
                    translatedText = [translatedText, text].filter { !$0.isEmpty }.joined(separator: " ")
                }
                confidence = text.isEmpty ? 0 : Self.confidence(for: segments)
                submittedSampleCount += utterance.samples.count
                completedDecodeCount += 1
                logDecodeMetrics(utterance, results: results, wallSeconds: wallSeconds)
            }
        }
        buffer.reset()
    }

    private func logModelMetrics(_ kit: WhisperKit) {
        let wallTime = modelLoadStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let timings = kit.currentTimings
        logger.info("""
            Model ready: \(String(describing: kit.modelFolder), privacy: .public)
              model compute: encoder: \(String(describing: kit.modelCompute.audioEncoderCompute), privacy: .public)
                             decoder: \(String(describing: kit.modelCompute.textDecoderCompute), privacy: .public)
              wall time: \(wallTime, format: .fixed(precision: 3)) s
              model loading: \(timings.modelLoading, format: .fixed(precision: 3)) s
              prewarm: \(timings.prewarmLoadTime, format: .fixed(precision: 3)) s
              encoder load: \(timings.encoderLoadTime, format: .fixed(precision: 3)) s
              decoder load: \(timings.decoderLoadTime, format: .fixed(precision: 3)) s
              tokenizer load: \(timings.tokenizerLoadTime, format: .fixed(precision: 3)) s
            """)
        modelLoadStartedAt = nil
    }

    private func logDecodeMetrics(
        _ utterance: SpeechSequenceBuffer.Utterance,
        results: [TranscriptionResult], wallSeconds: Double
    ) {
        let audioSeconds = seconds(for: utterance.samples.count)
        let timings = TranscriptionUtilities.mergeTranscriptionResults(results).timings
        let speed = wallSeconds > 0 ? audioSeconds / wallSeconds : 0
        logger.info("""
            Utterance #\(self.completedDecodeCount), trigger=\(utterance.trigger.rawValue, privacy: .public)
              audio: \(audioSeconds, format: .fixed(precision: 3)) s
              speech: \(utterance.speechSeconds, format: .fixed(precision: 3)) s
              trailing silence: \(utterance.silenceSeconds, format: .fixed(precision: 3)) s
              transcription wall time: \(wallSeconds, format: .fixed(precision: 3)) s
              RTF: \(speed, format: .fixed(precision: 2))x
              model pipeline: \(timings.fullPipeline, format: .fixed(precision: 3)) s
              encoder: \(timings.encoding, format: .fixed(precision: 3)) s
              decoder: \(timings.decodingLoop, format: .fixed(precision: 3)) s
              fallbacks: \(timings.totalDecodingFallbacks, format: .fixed(precision: 0))
              confidence: \((self.confidence ?? 0), format: .fixed(precision: 3))
            """)
    }

    private func logRecordingSummary() {
        guard let recordingStartedAt else { return }
        let wallTime = Date().timeIntervalSince(recordingStartedAt)
        let audioSeconds = seconds(for: submittedSampleCount)
        logger.info("""
            Recording stopped
              wall time: \(wallTime, format: .fixed(precision: 2)) s
              audio processed: \(audioSeconds, format: .fixed(precision: 2)) s
              completed streaming decodes: \(self.completedDecodeCount)
            """)
        self.recordingStartedAt = nil
    }

    private func seconds(for sampleCount: Int) -> Double {
        Double(sampleCount) / Double(WhisperKit.sampleRate)
    }

    private static func removingSpecialTokens(from text: String) -> String {
        text
            .replacingOccurrences(
                of: #"<\|?[^<>]+\|?>"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shows the confidence estimate for only the newest segment. Whisper exposes
    /// its average token log-probability; exponentiating it gives a readable 0...1
    private static func confidence(for segments: [TranscriptionSegment]) -> Double? {
        guard let latestSegment = segments.last else { return nil }
        return min(max(exp(Double(latestSegment.avgLogprob)), 0), 1)
    }

    private static func weightedAverageLogProbability(for segments: [TranscriptionSegment]) -> Double {
        let weighted = segments.reduce(into: (sum: 0.0, count: 0)) { result, segment in
            let tokenCount = max(segment.tokens.count, 1)
            result.sum += Double(segment.avgLogprob) * Double(tokenCount)
            result.count += tokenCount
        }
        return weighted.count > 0 ? weighted.sum / Double(weighted.count) : 0
    }

    private func present(error: Error) {
        errorMessage = error.localizedDescription
        isShowingError = true
    }
}

private enum LiveTranslationError: LocalizedError {
    case tokenizerUnavailable
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .tokenizerUnavailable:
            return "Der Tokenizer des Sprachmodells konnte nicht geladen werden."
        case .microphonePermissionDenied:
            return "Erlaube den Mikrofonzugriff in den Einstellungen, um Sprache zu übersetzen."
        }
    }
}
