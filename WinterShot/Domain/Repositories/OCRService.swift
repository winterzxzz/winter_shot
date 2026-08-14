import Foundation

/// Abstraction over on-device text recognition.
/// Implemented in the Data layer with Apple Vision.
protocol OCRService {
    func recognizeText(in imageURL: URL) async throws -> String
}
