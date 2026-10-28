import CoreImage.CIFilterBuiltins
import UIKit

/// Printable QR codes for unlock keys.
enum QRCode {
    static func image(for payload: String, scale: CGFloat = 14) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
