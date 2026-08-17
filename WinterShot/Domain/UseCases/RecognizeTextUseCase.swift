import Foundation

/// Runs on-device OCR over a screenshot and returns the recognized text.
struct RecognizeTextUseCase {
    let ocrService: OCRService

    func execute(imageURL: URL, region: CGRect? = nil) async throws -> String {
        try await ocrService.recognizeText(in: imageURL, region: region)
    }
}
