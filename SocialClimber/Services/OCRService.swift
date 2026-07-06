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

/// On-device OCR via Apple's Vision framework. Nothing leaves the device.
///
/// The whole thing sits behind a single async function so the paste-text flow
/// and the screenshot flow can share the same downstream parsing/review UI. If
/// Vision is ever unavailable the call throws `.unsupported` cleanly.
enum OCRService {
    static func recognizeText(in image: UIImage) async throws -> String {
        #if canImport(Vision)
        guard let cgImage = image.cgImage else { throw OCRError.noImage }
        let orientation = image.cgImagePropertyOrientation

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: OCRError.failed(error.localizedDescription))
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                // Sort roughly top-to-bottom so message order is preserved
                // (Vision's boundingBox origin is bottom-left).
                let ordered = observations.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                let lines = ordered.compactMap { $0.topCandidates(1).first?.string }
                if lines.isEmpty {
                    continuation.resume(throwing: OCRError.noText)
                } else {
                    continuation.resume(returning: lines.joined(separator: "\n"))
                }
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: OCRError.failed(error.localizedDescription))
                }
            }
        }
        #else
        // TODO: Provide an alternative on-device OCR path if Vision is ever
        // unavailable. For now the paste-text flow remains fully functional.
        throw OCRError.unsupported
        #endif
    }
}

private extension UIImage {
    var cgImagePropertyOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
