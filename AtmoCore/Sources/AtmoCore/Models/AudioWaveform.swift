import Foundation

// MARK: - Audio Waveform
/// Streams audio samples into a fixed number of amplitude buckets — the
/// bars of the waveform the voice-memo renderer draws. Pure math, so the
/// platform layer only handles decoding.
public final class WaveformAccumulator {

    public let bucketCount: Int
    private let framesPerBucket: Int
    private var peaks: [Float]
    private var frameIndex = 0

    /// - Parameters:
    ///   - bucketCount: number of bars to produce.
    ///   - estimatedFrameCount: total sample frames expected (duration ×
    ///     sample rate); the divider that maps frames onto buckets.
    public init(bucketCount: Int, estimatedFrameCount: Int) {
        self.bucketCount = max(1, bucketCount)
        self.framesPerBucket = max(1, estimatedFrameCount / max(1, bucketCount))
        self.peaks = Array(repeating: 0, count: max(1, bucketCount))
    }

    /// Feed a chunk of mono samples (any chunking; order matters).
    public func add(_ samples: [Float]) {
        for sample in samples {
            let bucket = min(bucketCount - 1, frameIndex / framesPerBucket)
            let magnitude = abs(sample)
            if magnitude > peaks[bucket] { peaks[bucket] = magnitude }
            frameIndex += 1
        }
    }

    /// Bars normalized to 0…1 against the loudest bucket, with a small
    /// floor so silence still draws a visible baseline.
    public func normalizedBuckets(floor minimum: Float = 0.06) -> [Float] {
        let peak = peaks.max() ?? 0
        guard peak > 0 else { return Array(repeating: minimum, count: bucketCount) }
        return peaks.map { max(minimum, $0 / peak) }
    }
}
