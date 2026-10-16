//
//  VisionReceiptTextRecognizer.swift
//  Folio
//
//  Created by Divy Patel on 16/10/2026.
//


import Foundation
import Vision

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



actor VisionReceiptTextRecognizer: ReceiptTextRecognizing {

    func recognize(imageData: Data) async throws -> String {
        try Task.checkCancellation()

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(
            data: imageData,
            options: [:]
        )

        try handler.perform([request])

        let lines = (request.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }

        return lines.joined(separator: "\n")
    }
}
