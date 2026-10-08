import Foundation

nonisolated struct SpeechSequenceBuffer {
    enum Trigger: String { case silence, maximumLength }
    struct Utterance {
        let samples: [Float]
        let speechSeconds: Double
        let silenceSeconds: Double
        let trigger: Trigger
    }

    private(set) var samples: [Float] = []
    private(set) var speechSamples = 0
    private(set) var silenceSamples = 0
    let sampleRate = 16_000

    mutating func append(_ chunk: [Float], isSpeech: Bool) -> Utterance? {
        samples.append(contentsOf: chunk)
        if isSpeech {
            silenceSamples = 0
            speechSamples += chunk.count
        } else {
            silenceSamples += chunk.count
        }

        let endpoint = silenceSamples > 12_000 && speechSamples > 4_000
        let tooLong = samples.count > sampleRate * 10
        if endpoint || tooLong {
            let utterance = Utterance(
                samples: samples,
                speechSeconds: Double(speechSamples) / Double(sampleRate),
                silenceSeconds: Double(silenceSamples) / Double(sampleRate),
                trigger: tooLong ? .maximumLength : .silence
            )
            reset()
            return utterance
        }

        if silenceSamples > 12_000 { reset() }
        return nil
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        speechSamples = 0
        silenceSamples = 0
    }
}
