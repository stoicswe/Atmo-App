import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import AtmoCore

// MARK: - Waveform Video Renderer
/// Turns an audio clip into a "voice memo" video Bluesky can host: the
/// audio track re-encoded to AAC under an animated waveform (played bars
/// tint in accent blue as a playhead sweeps). Output is an H.264 MP4 that
/// goes straight through the existing video-embed pipeline.
enum WaveformVideoRenderer {

    struct Rendered {
        let data: Data
        let fileName: String
        let aspectRatio: (width: Int, height: Int)
        let duration: TimeInterval
    }

    enum RenderError: Error {
        case unreadableAudio
        case writerFailed
    }

    private static let width = 1080
    private static let height = 540
    private static let fps: Int32 = 12
    private static let barCount = 64

    static func render(audioURL: URL) async throws -> Rendered {
        let asset = AVURLAsset(url: audioURL)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0.2
        else { throw RenderError.unreadableAudio }
        if let violation = VideoConstraints.validate(byteCount: 0, duration: duration) {
            throw violation
        }
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw RenderError.unreadableAudio
        }

        let buckets = try waveformBuckets(asset: asset, track: audioTrack, duration: duration)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atmo-voice-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 900_000],
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        // Re-encode the audio to AAC so any input (m4a, mp3, wav) lands in
        // a valid MP4 uniformly.
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ])
        audioInput.expectsMediaDataInRealTime = false

        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else { throw RenderError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        // ── Video frames ──
        let frameCount = max(1, Int(duration * Double(fps)))
        for frame in 0..<frameCount {
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(4))
            }
            let progress = Double(frame) / Double(max(1, frameCount - 1))
            guard let buffer = makeFrame(progress: progress, buckets: buckets, pool: adaptor.pixelBufferPool) else {
                throw RenderError.writerFailed
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps))
        }
        videoInput.markAsFinished()

        // ── Audio (decoded to PCM, re-encoded by the writer) ──
        let reader = try AVAssetReader(asset: asset)
        let pcmOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
        ])
        reader.add(pcmOutput)
        reader.startReading()
        while let sample = pcmOutput.copyNextSampleBuffer() {
            while !audioInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(4))
            }
            audioInput.append(sample)
        }
        audioInput.markAsFinished()

        await writer.finishWriting()
        guard writer.status == .completed else { throw RenderError.writerFailed }

        let data = try Data(contentsOf: outputURL)
        return Rendered(
            data: data,
            fileName: "voice-\(UUID().uuidString).mp4",
            aspectRatio: (width, height),
            duration: duration
        )
    }

    // MARK: Waveform extraction

    private static func waveformBuckets(
        asset: AVURLAsset,
        track: AVAssetTrack,
        duration: TimeInterval
    ) throws -> [Float] {
        let sampleRate = 22_050
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        reader.startReading()

        let accumulator = WaveformAccumulator(
            bucketCount: barCount,
            estimatedFrameCount: Int(duration * Double(sampleRate))
        )
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var raw = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            raw.withUnsafeMutableBytes { pointer in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: pointer.baseAddress!)
            }
            accumulator.add(raw)
        }
        guard reader.status == .completed else { throw RenderError.unreadableAudio }
        return accumulator.normalizedBuckets()
    }

    // MARK: Frame drawing

    private static func makeFrame(
        progress: Double,
        buckets: [Float],
        pool: CVPixelBufferPool?
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        guard let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Backdrop
        context.setFillColor(CGColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Bars, centered vertically; played portion tints Bluesky blue.
        let sideMargin: CGFloat = 60
        let usable = CGFloat(width) - sideMargin * 2
        let slot = usable / CGFloat(buckets.count)
        let barWidth = slot * 0.62
        let maxBarHeight: CGFloat = CGFloat(height) - 160
        let played = CGColor(red: 0.063, green: 0.514, blue: 0.996, alpha: 1)
        let idle = CGColor(gray: 1.0, alpha: 0.32)

        for (index, bucket) in buckets.enumerated() {
            let fraction = (Double(index) + 0.5) / Double(buckets.count)
            context.setFillColor(fraction <= progress ? played : idle)
            let barHeight = max(6, CGFloat(bucket) * maxBarHeight)
            let rect = CGRect(
                x: sideMargin + CGFloat(index) * slot + (slot - barWidth) / 2,
                y: (CGFloat(height) - barHeight) / 2,
                width: barWidth,
                height: barHeight
            )
            let path = CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
            context.addPath(path)
            context.fillPath()
        }

        return buffer
    }
}
