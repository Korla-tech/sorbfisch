import Foundation
import WhisperKit

nonisolated struct DebugDecodeResult: Sendable {
    let text: String
    let language: String
    let segments: [TranscriptionSegment]
}

nonisolated struct DebugSegmentLog: Codable, Sendable {
    let resultIndex: Int
    let audioFile: String
    let audioStartSample: Int
    let audioEndSampleExclusive: Int
    let audioRangeWasClamped: Bool
    let confidence: Double?
    let outputText: String
    let displayedText: String
    // Includes original text, timestamps, token IDs, token log probabilities,
    // average log probability, no-speech probability, temperature and words.
    let decoderSegment: TranscriptionSegment
}

nonisolated struct DebugDecodeLog: Codable, Sendable {
    let schemaVersion: Int
    let createdAt: Date
    let inputAudioFile: String
    let sampleRate: Int
    let inputSampleCount: Int
    let trigger: String
    let speechSeconds: Double
    let trailingSilenceSeconds: Double
    var status: String
    var decodeSeconds: Double?
    var error: String?
    var generatedOutput: String?
    var detectedLanguages: [String]?
    var segments: [DebugSegmentLog]
}

nonisolated struct DebugDecodeCapture: Sendable {
    let directory: URL
    var log: DebugDecodeLog
}

/// All disk work is serialized away from the UI. Capture is available in every
/// build, but callers must explicitly enable it per launch.
actor DebugRecordingStore {
    private let rootOverride: URL?

    init(rootDirectory: URL? = nil) {
        rootOverride = rootDirectory
    }

    private func rootDirectory() throws -> URL {
        if let rootOverride { return rootOverride }
        return try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("DeveloperRecordings", isDirectory: true)
    }

    func startSession(id: UUID, outputLanguage: String, model: String) throws -> URL {
        var root = try rootDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try root.setResourceValues(resourceValues)
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata: [String: String] = [
            "sessionID": id.uuidString,
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "outputLanguage": outputLanguage,
            "model": model,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "system": ProcessInfo.processInfo.operatingSystemVersionString,
            "audioFormat": "WAV, mono, 16000 Hz, IEEE 754 float32 little endian; exact decoder input samples",
            "segmentAudio": "Ranges use decoder timestamps relative to input.wav, clamped to input bounds. End sample is exclusive.",
            "confidence": "exp(avgLogprob), clamped to 0...1; not a calibrated accuracy score. Non-finite confidence is omitted.",
            "displayedText": "Text after the app's filtering rules; a cancelled recording may prevent it from reaching the UI.",
            "nonFiniteNumbers": "NaN and infinities in raw decoder metadata are encoded as strings."
        ]
        try writeJSON(metadata, to: directory.appendingPathComponent("session.json"))
        return directory
    }

    func beginDecode(session: URL, index: Int, utterance: SpeechSequenceBuffer.Utterance) throws -> DebugDecodeCapture {
        let directory = session.appendingPathComponent(String(format: "decode-%04d", index), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeWAV(utterance.samples, to: directory.appendingPathComponent("input.wav"))
        let capture = DebugDecodeCapture(directory: directory, log: DebugDecodeLog(
            schemaVersion: 1, createdAt: Date(), inputAudioFile: "input.wav",
            sampleRate: 16_000, inputSampleCount: utterance.samples.count,
            trigger: utterance.trigger.rawValue, speechSeconds: utterance.speechSeconds,
            trailingSilenceSeconds: utterance.silenceSeconds,
            status: "decoding", segments: []
        ))
        // Persist before inference so failed/cancelled decodes retain their input.
        try writeJSON(capture.log, to: directory.appendingPathComponent("decode.json"))
        return capture
    }

    func completeDecode(_ capture: DebugDecodeCapture, samples: [Float], results: [DebugDecodeResult], seconds: Double) throws {
        var log = capture.log
        log.decodeSeconds = seconds
        log.generatedOutput = results.map(\.text).joined(separator: " ")
        log.detectedLanguages = results.map(\.language)
        for (resultIndex, result) in results.enumerated() {
            for segment in result.segments {
                let start = sampleIndex(segment.start, count: samples.count, rounding: .down)
                let end = max(start, sampleIndex(segment.end, count: samples.count, rounding: .up))
                let audioFile = String(format: "segment-%04d.wav", log.segments.count + 1)
                try writeWAV(Array(samples[start..<end]), to: capture.directory.appendingPathComponent(audioFile))
                let confidence = exp(Double(segment.avgLogprob))
                let text = segment.text
                    .replacingOccurrences(of: #"<\|?[^<>]+\|?>"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                log.segments.append(DebugSegmentLog(
                    resultIndex: resultIndex, audioFile: audioFile,
                    audioStartSample: start, audioEndSampleExclusive: end,
                    audioRangeWasClamped: !segment.start.isFinite || !segment.end.isFinite
                        || segment.start < 0 || segment.end < segment.start
                        || Double(segment.end) * 16_000 > Double(samples.count),
                    confidence: confidence.isFinite ? min(max(confidence, 0), 1) : nil,
                    outputText: text,
                    displayedText: text.isEmpty ? "" : (!confidence.isFinite || confidence < 0.5 ? "unverständlich" : text),
                    decoderSegment: segment
                ))
            }
        }
        log.status = "completed"
        try writeJSON(log, to: capture.directory.appendingPathComponent("decode.json"))
    }

    func failDecode(_ capture: DebugDecodeCapture, error: Error) throws {
        var log = capture.log
        log.status = error is CancellationError ? "cancelled" : "failed"
        log.error = String(describing: error)
        try writeJSON(log, to: capture.directory.appendingPathComponent("decode.json"))
    }

    func exportArchive() throws -> URL {
        let root = try rootDirectory()
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SorbfischDebugExports", isDirectory: true)
        // Exports are prepared only while stopped; keep one temporary snapshot.
        if FileManager.default.fileExists(atPath: exportDirectory.path) {
            try FileManager.default.removeItem(at: exportDirectory)
        }
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let destination = exportDirectory.appendingPathComponent("Sorbfisch-Debug-\(UUID().uuidString).zip")
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: root, options: .forUploading, error: &coordinationError) { archive in
            do { try FileManager.default.copyItem(at: archive, to: destination) }
            catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        return destination
    }

    func deleteRecordings() throws {
        let root = try rootDirectory()
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        let exports = FileManager.default.temporaryDirectory.appendingPathComponent("SorbfischDebugExports", isDirectory: true)
        if FileManager.default.fileExists(atPath: exports.path) {
            try FileManager.default.removeItem(at: exports)
        }
    }

    private func sampleIndex(_ seconds: Float, count: Int, rounding: FloatingPointRoundingRule) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int(min(max(Double(seconds) * 16_000, 0), Double(count)).rounded(rounding))
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func writeWAV(_ samples: [Float], to url: URL) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(samples.count * MemoryLayout<Float>.size)
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(50) + byteCount)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(18))
        append(UInt16(3)) // IEEE float, preserving the exact decoder samples.
        append(UInt16(1))
        append(UInt32(16_000))
        append(UInt32(64_000))
        append(UInt16(4))
        append(UInt16(32))
        append(UInt16(0)) // WAVEFORMATEX extension size.
        data.append(contentsOf: "fact".utf8)
        append(UInt32(4))
        append(UInt32(samples.count))
        data.append(contentsOf: "data".utf8)
        append(byteCount)
        for sample in samples { append(sample.bitPattern) }
        try data.write(to: url, options: .atomic)
    }
}
