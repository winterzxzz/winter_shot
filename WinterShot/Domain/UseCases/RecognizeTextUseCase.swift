import Foundation

/// Runs on-device OCR over a screenshot and returns the recognized text.
struct RecognizeTextUseCase {
    let ocrService: OCRService

    func execute(imageURL: URL) async throws -> String {
        try await ocrService.recognizeText(in: imageURL)
    }
}
