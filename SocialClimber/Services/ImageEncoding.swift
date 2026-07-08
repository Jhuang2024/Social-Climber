import UIKit

/// Shared helper for turning a `UIImage` into a compact base64 data URL
/// suitable for a vision-capable chat completion request (Fit Checker, How
/// to Respond). Keeping this in one place means every vision call site
/// downsizes and compresses the same way instead of each shipping a
/// full-resolution photo.
enum ImageEncoding {
    /// Downscales to `maxDimension` on the longer side and JPEG-compresses,
    /// so a photo fits comfortably in a vision request without ballooning
    /// payload size or wait time. Returns `nil` only if JPEG encoding itself
    /// fails (corrupt image data).
    static func dataURL(for image: UIImage, maxDimension: CGFloat = 1024, quality: CGFloat = 0.7) -> String? {
        let resized = resized(image, maxDimension: maxDimension)
        guard let data = resized.jpegData(compressionQuality: quality) else { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension, longestSide > 0 else { return image }
        let scale = maxDimension / longestSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
