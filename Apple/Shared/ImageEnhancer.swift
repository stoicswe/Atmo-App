import Foundation
import CoreImage
import ImageIO
import AtmoCore
#if canImport(Vision)
import Vision
#endif
#if canImport(CoreML)
import CoreML
#endif

// MARK: - Image Enhancer
/// "Enhance" for a full-screen image: fetch the author's original upload
/// from their PDS (falling back to the CDN's largest preset), then bring
/// the long edge toward 4K with a deliberately natural resample — see
/// `upscale`. With a Core ML super-resolution model in the bundle
/// (`Upscaler.mlmodelc`, image in → image out) the model supplies the
/// detail. Output is a JPEG, ready for Photos and the cache.
enum ImageEnhancer {

    enum EnhanceError: Error { case decodeFailed, renderFailed }

    /// Target long edge in pixels.
    static let targetLongEdge: CGFloat = 3840

    /// True when a super-resolution model ships in the app bundle.
    static var hasNeuralModel: Bool { modelURL != nil }

    private static var modelURL: URL? {
        Bundle.main.url(forResource: "Upscaler", withExtension: "mlmodelc")
    }

    /// Enhances the image at `url`: the author's original upload when the
    /// PDS will hand it over (real detail — the CDN presets are re-encoded
    /// copies), else the largest CDN preset; then a gentle upscale.
    static func enhance(_ url: URL) async throws -> Data {
        let data: Data
        if let original = await OriginalImageSource.fetchOriginal(for: url) {
            data = original
        } else {
            let source = BlueskyCDN.feedFullsize(url)
            let request = URLRequest(url: source, cachePolicy: .returnCacheDataElseLoad)
            data = try await URLSession.cachedSession.data(for: request).0
        }
        return try await Task.detached(priority: .userInitiated) {
            try upscale(data)
        }.value
    }

    /// Natural upscale, tuned to not look processed:
    ///   • at most 2× — larger factors invent detail and read as synthetic;
    ///   • a light deblock/denoise BEFORE scaling so compression grain
    ///     isn't magnified;
    ///   • Mitchell–Netravali bicubic (B = C = ⅓) rather than Lanczos, which
    ///     rings on hard edges;
    ///   • no sharpening. A bundled Core ML model, when present, supplies
    ///     the detail instead.
    nonisolated static func upscale(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              )
        else { throw EnhanceError.decodeFailed }

        var image = CIImage(cgImage: cgImage)
        let usedModel: Bool
        if let modelURL, let modelled = neuralUpscale(image, modelURL: modelURL) {
            image = modelled
            usedModel = true
        } else {
            usedModel = false
        }

        let longEdge = max(image.extent.width, image.extent.height)
        let scale = min(2.0, targetLongEdge / longEdge)
        if scale > 1.02 {
            if !usedModel {
                // Take the compression grain down a notch before it gets
                // magnified — subtle enough to leave texture alone.
                image = image.applyingFilter("CINoiseReduction", parameters: [
                    "inputNoiseLevel": 0.015,
                    "inputSharpness": 0.2,
                ])
            }
            image = image.applyingFilter("CIBicubicScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1.0,
                "inputB": 1.0 / 3.0,
                "inputC": 1.0 / 3.0,
            ])
        }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let jpeg = context.jpegRepresentation(
            of: image, colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95]
        ) else { throw EnhanceError.renderFailed }
        return jpeg
    }

    /// Runs the bundled super-resolution model, if any. Returns nil when
    /// the model can't be loaded or yields nothing usable.
    private nonisolated static func neuralUpscale(_ image: CIImage, modelURL: URL) -> CIImage? {
#if canImport(Vision) && canImport(CoreML)
        guard let model = try? MLModel(contentsOf: modelURL),
              let vnModel = try? VNCoreMLModel(for: model)
        else { return nil }
        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(ciImage: image)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNPixelBufferObservation
        else { return nil }
        return CIImage(cvPixelBuffer: observation.pixelBuffer)
#else
        return nil
#endif
    }
}
