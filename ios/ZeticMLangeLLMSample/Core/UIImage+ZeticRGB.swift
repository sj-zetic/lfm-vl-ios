import UIKit
import ZeticMLange

enum ImageConversionError: LocalizedError {
    case noCGImage
    case invalidDimensions
    case drawFailed

    var errorDescription: String? {
        switch self {
        case .noCGImage: return "That image could not be decoded."
        case .invalidDimensions: return "That image has unusable dimensions."
        case .drawFailed: return "That image could not be converted for the model."
        }
    }
}

extension UIImage {
    /// Converts to the packed 24-bit RGB buffer the model expects.
    ///
    /// Camera photos carry their rotation in `imageOrientation` rather than in the
    /// pixel data, and `CGImage` ignores it — so the image is redrawn upright and
    /// downscaled in one pass before the channels are packed.
    func zeticRGBImage(maxDimension: CGFloat = Constants.maxImageDimension) throws -> ZeticMLangeLLMModel.Image {
        let upright = try resizedUpright(maxDimension: maxDimension)
        guard let cgImage = upright.cgImage else { throw ImageConversionError.noCGImage }

        let width = cgImage.width
        let height = cgImage.height
        guard
            let rgbaByteCount = ZeticMLangeLLMModel.Image.byteCount(width: width, height: height, channels: 4),
            let rgbByteCount = ZeticMLangeLLMModel.Image.byteCount(width: width, height: height, channels: 3)
        else { throw ImageConversionError.invalidDimensions }

        var rgba = [UInt8](repeating: 0, count: rgbaByteCount)
        let drew = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let baseAddress = buffer.baseAddress,
                let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { throw ImageConversionError.drawFailed }

        var rgb = [UInt8](repeating: 0, count: rgbByteCount)
        var source = 0
        var output = 0
        while output < rgb.count {
            rgb[output] = rgba[source]
            rgb[output + 1] = rgba[source + 1]
            rgb[output + 2] = rgba[source + 2]
            source += 4
            output += 3
        }

        return try ZeticMLangeLLMModel.Image(rgb: rgb, width: width, height: height)
    }

    /// Redraws the image upright, scaled so its longest edge is at most `maxDimension`.
    private func resizedUpright(maxDimension: CGFloat) throws -> UIImage {
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        // `draw(in:)` honours imageOrientation, so the result is always upright.
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
