import Foundation
import UIKit
#if canImport(Vision)
import Vision
#endif

enum OCRError: LocalizedError {
    case noImage
    case noText
    case failed(String)
    case unsupported

    var errorDescription: String? {
        switch self {
        case .noImage: "That image couldn't be read. Try another screenshot."
        case .noText: "No text was found in that screenshot."
        case .failed(let message): "Couldn't scan the screenshot: \(message)"
        case .unsupported: "On-device text recognition isn't available on this device."
        }
    }
}

/// Who a recognized chat line most likely belongs to, guessed from its
/// bubble's background color.
enum ChatBubbleSender: String {
    case me = "Me"
    case them = "Them"
}

/// On-device OCR via Apple's Vision framework. Nothing leaves the device.
///
/// The whole thing sits behind a single async function so the paste-text flow
/// and the screenshot flow can share the same downstream parsing/review UI. If
/// Vision is ever unavailable the call throws `.unsupported` cleanly.
///
/// Each recognized line is also sampled for its bubble's background color and
/// prefixed with "Me:" / "Them:" when that color is a confident match — solid
/// blue (iMessage/SMS) or a blue-to-purple gradient (Instagram) for the
/// device owner, near-black/dark-gray for the other person on both. A line
/// with no confident color read (plain backgrounds, status labels, system
/// text) is left exactly as recognized, so this can only ever add
/// information, never remove or corrupt any of it.
enum OCRService {
    static func recognizeText(in image: UIImage) async throws -> String {
        #if canImport(Vision)
        guard let cgImage = normalizedCGImage(from: image) else { throw OCRError.noImage }

        let observations: [VNRecognizedTextObservation] = try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: OCRError.failed(error.localizedDescription))
                    return
                }
                continuation.resume(returning: (request.results as? [VNRecognizedTextObservation]) ?? [])
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: OCRError.failed(error.localizedDescription))
                }
            }
        }

        // Sort roughly top-to-bottom so message order is preserved
        // (Vision's boundingBox origin is bottom-left).
        let ordered = observations.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        let sampler = ChatBubbleColorSampler(cgImage: cgImage)
        let lines: [String] = ordered.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            guard let sender = sampler?.sender(around: observation.boundingBox) else { return text }
            return "\(sender.rawValue): \(text)"
        }
        guard !lines.isEmpty else { throw OCRError.noText }
        return lines.joined(separator: "\n")
        #else
        // TODO: Provide an alternative on-device OCR path if Vision is ever
        // unavailable. For now the paste-text flow remains fully functional.
        throw OCRError.unsupported
        #endif
    }

    /// Redraws the image with its orientation baked in so Vision's
    /// normalized bounding boxes and this file's raw pixel sampling agree on
    /// the same coordinate space. Screenshots are already `.up`, so this is
    /// a no-op copy in the common case.
    private static func normalizedCGImage(from image: UIImage) -> CGImage? {
        guard image.imageOrientation != .up else { return image.cgImage }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        let normalized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return normalized.cgImage
    }
}

#if canImport(Vision)
/// Samples pixel colors just outside a recognized text line's bounding box —
/// inside its chat bubble, but avoiding the white/light text glyphs
/// themselves — and classifies the result as the device owner's bubble or
/// the other person's. Built once per image and reused across every line.
private struct ChatBubbleColorSampler {
    private let width: Int
    private let height: Int
    // The context owns the backing buffer `data` points into, so it's kept
    // alive alongside it for the sampler's whole lifetime — letting `context`
    // deallocate while still holding its raw pointer would be a use-after-free.
    private let context: CGContext
    private let data: UnsafeMutablePointer<UInt8>

    init?(cgImage: CGImage) {
        width = cgImage.width
        height = cgImage.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let raw = context.data
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.context = context
        data = raw.bindMemory(to: UInt8.self, capacity: width * height * 4)
    }

    /// `normalizedBox` is Vision's boundingBox: normalized 0...1, origin
    /// bottom-left. Returns `nil` when no sample point lands on a confident
    /// bubble color.
    func sender(around normalizedBox: CGRect) -> ChatBubbleSender? {
        let boxWidth = normalizedBox.width * CGFloat(width)
        let minX = normalizedBox.minX * CGFloat(width)
        let midY = (1 - normalizedBox.midY) * CGFloat(height)
        // Flip Vision's bottom-left-origin Y into this buffer's top-left space.
        let topY = (1 - normalizedBox.maxY) * CGFloat(height)
        let bottomY = (1 - normalizedBox.minY) * CGFloat(height)
        let margin = max(6, normalizedBox.height * CGFloat(height) * 0.4)

        let candidates: [CGPoint] = [
            CGPoint(x: minX - margin, y: midY),
            CGPoint(x: minX + boxWidth + margin, y: midY),
            CGPoint(x: minX + boxWidth * 0.25, y: topY - margin),
            CGPoint(x: minX + boxWidth * 0.25, y: bottomY + margin),
            CGPoint(x: minX + boxWidth * 0.75, y: topY - margin),
            CGPoint(x: minX + boxWidth * 0.75, y: bottomY + margin),
        ]

        let samples = candidates.compactMap { pixel(x: Int($0.x), y: Int($0.y)) }
        guard !samples.isEmpty else { return nil }

        let count = CGFloat(samples.count)
        let avgR = samples.reduce(0) { $0 + $1.r } / count
        let avgG = samples.reduce(0) { $0 + $1.g } / count
        let avgB = samples.reduce(0) { $0 + $1.b } / count
        return classify(r: avgR, g: avgG, b: avgB)
    }

    private func pixel(x: Int, y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let offset = (y * width + x) * 4
        return (
            CGFloat(data[offset]) / 255,
            CGFloat(data[offset + 1]) / 255,
            CGFloat(data[offset + 2]) / 255
        )
    }

    /// Deliberately conservative: an ambiguous read (a plain white/light
    /// background, a system label, anything without a strong hue or a
    /// clearly dark bubble) is left unattributed rather than guessed.
    private func classify(r: CGFloat, g: CGFloat, b: CGFloat) -> ChatBubbleSender? {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let degrees = hue * 360

        // Near-black / dark gray bubble — the other person, on both
        // Instagram and Messages/SMS.
        if brightness < 0.32, saturation < 0.35 {
            return .them
        }
        // Blue through purple with real saturation — the device owner,
        // covering iMessage/SMS's solid blue and Instagram's blue-to-purple
        // gradient. The brightness floor keeps a dark, low-saturation misread
        // from slipping in here instead of `.them`.
        if degrees >= 195, degrees <= 300, saturation > 0.25, brightness > 0.25 {
            return .me
        }
        return nil
    }
}
#endif
