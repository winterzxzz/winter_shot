import Foundation

/// Abstraction over on-device text recognition.
/// Implemented in the Data layer with Apple Vision.
protocol OCRService {
    /// Recognizes text in the image, limited to `region` (image pixels,
    /// top-left origin) when given.
    func recognizeText(in imageURL: URL, region: CGRect?) async throws -> String
}
