nonisolated struct VADAudioFrames {
    static let frameSize = 4096 // Silero v6.2.1: 256 ms at 16 kHz
    private var pending: [Float] = []

    mutating func append(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        let count = pending.count / Self.frameSize
        guard count > 0 else { return [] }
        let frames = (0..<count).map { index in
            let start = index * Self.frameSize
            return Array(pending[start..<(start + Self.frameSize)])
        }
        pending.removeFirst(count * Self.frameSize)
        return frames
    }
}
