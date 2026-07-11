import UIKit
import CoreImage
import os

enum QRCodeGenerator {

    // MARK: - Types

    struct PairingPayload: Codable, Sendable {
        let ip: String
        let port: UInt16
        let password: String
        let proto: String

        enum CodingKeys: String, CodingKey {
            case ip, port, password, proto
        }
    }

    // MARK: - Errors

    enum QRCodeError: Error, LocalizedError {
        case filterCreationFailed
        case imageCreationFailed
        case renderingFailed
        case dataEncodingFailed

        var errorDescription: String? {
            switch self {
            case .filterCreationFailed: return "Failed to create QR code generator filter"
            case .imageCreationFailed: return "Failed to generate CIImage from filter"
            case .renderingFailed: return "Failed to render CIImage to CGContext"
            case .dataEncodingFailed: return "Failed to encode data to UTF-8"
            }
        }
    }

    // MARK: - Constants

    private static let scale: CGFloat = 8.0
    private static let quietZone: CGFloat = 4.0
    private static let logger = Logger(subsystem: "com.rifatcam.pro", category: "QRCodeGenerator")

    // MARK: - Public API

    static func generatePairingQR(
        ip: String,
        port: UInt16,
        password: String,
        proto: String = "tcp"
    ) -> UIImage? {
        let payload = PairingPayload(ip: ip, port: port, password: password, proto: proto)
        guard let jsonData = try? JSONEncoder().encode(payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            logger.error("Failed to encode pairing payload to JSON")
            return nil
        }
        return generateQR(from: jsonString)
    }

    static func generatePairingString(
        ip: String,
        port: UInt16,
        password: String,
        proto: String = "tcp"
    ) -> String? {
        let payload = PairingPayload(ip: ip, port: port, password: password, proto: proto)
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func generateQR(from string: String) -> UIImage? {
        guard let data = string.data(using: .utf8) else {
            logger.error("Failed to convert string to UTF-8 data")
            return nil
        }
        return generateQR(from: data)
    }

    static func generateQR(from data: Data) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            logger.error("CIQRCodeGenerator filter not available")
            return nil
        }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else {
            logger.error("Filter produced no output image")
            return nil
        }

        return renderCIImageToUIImage(ciImage)
    }

    // MARK: - Rendering

    private static func renderCIImageToUIImage(_ ciImage: CIImage) -> UIImage? {
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let sizeInPoints = CGSize(
            width: extent.width * scale + quietZone * 2 * scale,
            height: extent.height * scale + quietZone * 2 * scale
        )

        let pixelWidth = Int(sizeInPoints.width * UIScreen.main.scale)
        let pixelHeight = Int(sizeInPoints.height * UIScreen.main.scale)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            logger.error("Failed to create CGContext")
            return nil
        }

        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: CGSize(width: pixelWidth, height: pixelHeight)))

        let ctx = CIContext(cgContext: context, options: [.useSoftwareRenderer: false])

        let drawRect = CGRect(
            x: quietZone * scale * UIScreen.main.scale,
            y: quietZone * scale * UIScreen.main.scale,
            width: extent.width * scale * UIScreen.main.scale,
            height: extent.height * scale * UIScreen.main.scale
        )

        ctx.draw(ciImage, in: drawRect)

        guard let cgImage = context.makeImage() else {
            logger.error("Failed to create CGImage from context")
            return nil
        }

        return UIImage(cgImage: cgImage, scale: UIScreen.main.scale, orientation: .up)
    }

    // MARK: - Data-Only QR

    static func generateQRData(from string: String) -> Data? {
        return generateQR(from: string)?.pngData()
    }
}
