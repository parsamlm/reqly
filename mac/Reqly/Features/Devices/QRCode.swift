import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum QRCode {
    /// A QR code for `text`, black on white, with each module a whole number of pixels.
    static func image(for text: String, pixelsPerModule: CGFloat = 8) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let scaled = code.samplingNearest().transformed(
            by: CGAffineTransform(scaleX: pixelsPerModule, y: pixelsPerModule))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
