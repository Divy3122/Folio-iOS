import Foundation
import Vision
import UIKit
import ImageIO

enum ScannerError: LocalizedError {
    case imageConversionFailed
    case noPages
    case noReadableText

    var errorDescription: String? {
        switch self {
        case .imageConversionFailed:
            return "The scanned image could not be processed."
        case .noPages:
            return "No receipt pages were captured."
        case .noReadableText:
            return "No readable text was found. Try scanning again."
        }
    }
}

/// Captures original Vision evidence while keeping the existing string contract.
/// No extra OCR requests are needed: one Vision pass produces both outputs.
actor VisionReceiptTextRecognizer: ReceiptEvidenceRecognizing {
    func recognize(imageData: Data) async throws -> String {
        try await recognizeEvidence(imageData: imageData).text
    }

    func recognizeEvidence(imageData: Data) async throws -> ReceiptOCRPage {
        try Task.checkCancellation()
        guard let image = UIImage(data: imageData),
              let cgImage = image.cgImage else {
            throw ScannerError.imageConversionFailed
        }

        let orientation: CGImagePropertyOrientation
        switch image.imageOrientation {
        case .up: orientation = .up
        case .down: orientation = .down
        case .left: orientation = .left
        case .right: orientation = .right
        case .upMirrored: orientation = .upMirrored
        case .downMirrored: orientation = .downMirrored
        case .leftMirrored: orientation = .leftMirrored
        case .rightMirrored: orientation = .rightMirrored
        @unknown default: orientation = .up
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
        try handler.perform([request])
        try Task.checkCancellation()

        let fragments: [ReceiptOCRFragment] = (request.results ?? []).compactMap { observation in
            let candidates = observation.topCandidates(3).compactMap { candidate -> ReceiptOCRCandidate? in
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return ReceiptOCRCandidate(text: text, confidence: Double(candidate.confidence))
            }
            guard !candidates.isEmpty else { return nil }
            let rect = observation.boundingBox
            return ReceiptOCRFragment(
                box: ReceiptOCRBox(
                    x: Double(rect.minX), y: Double(rect.minY),
                    width: Double(rect.width), height: Double(rect.height)
                ),
                candidates: candidates
            )
        }
        return ReceiptOCRPage(pageNumber: 1, lines: ReceiptOCRLayout.lines(from: fragments))
    }
}
