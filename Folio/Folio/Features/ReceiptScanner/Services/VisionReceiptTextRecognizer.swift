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

/// Adapted from the supplied camera-reciept-test project's ReceiptOCR.
/// Retains Folio's shared single-image protocol and spatial row reconstruction.
/// Receipts with multiple pages are handled by ReceiptScannerViewModel.
actor VisionReceiptTextRecognizer: ReceiptTextRecognizing {
    func recognize(imageData: Data) async throws -> String {
        try Task.checkCancellation()

        // The reference scanner passes a CGImage AND its original orientation
        // to Vision. Doing both avoids text being read sideways or upside down.
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

        // Same CGImage + orientation Vision API as the supplied application.
        // The surrounding Folio actor already runs off the main actor.
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: orientation
        )
        try handler.perform([request])
        try Task.checkCancellation()

        // Folio previously needed spatial reconstruction to keep item names
        // beside their right-aligned prices. Keep this proven behaviour.
        struct Fragment {
            let text: String
            let x: CGFloat
            let y: CGFloat
            let height: CGFloat
        }
        struct Row {
            var y: CGFloat
            var height: CGFloat
            var fragments: [Fragment]
        }

        let fragments: [Fragment] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Fragment(
                text: text,
                x: observation.boundingBox.minX,
                y: observation.boundingBox.midY,
                height: observation.boundingBox.height
            )
        }.sorted { lhs, rhs in
            if abs(lhs.y - rhs.y) < 0.002 { return lhs.x < rhs.x }
            return lhs.y > rhs.y
        }

        var rows: [Row] = []
        for fragment in fragments {
            if let lastIndex = rows.indices.last,
               abs(rows[lastIndex].y - fragment.y) <=
                max(0.005, min(rows[lastIndex].height, fragment.height) * 0.46) {
                rows[lastIndex].fragments.append(fragment)
            } else {
                rows.append(Row(
                    y: fragment.y,
                    height: fragment.height,
                    fragments: [fragment]
                ))
            }
        }

        return rows.map { row in
            row.fragments.sorted { $0.x < $1.x }
                .map(\.text)
                .joined(separator: "   ")
        }.joined(separator: "\n")
    }
}
