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

/// Keeps each product and its right-hand-side price on the same logical OCR row.
/// Vision returns recognised observations, not a guaranteed reading-order table.
actor VisionReceiptTextRecognizer: ReceiptTextRecognizing {
    func recognize(imageData: Data) async throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        try VNImageRequestHandler(data: imageData, options: [:]).perform([request])
        try Task.checkCancellation()

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
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Fragment(text: text,
                            x: observation.boundingBox.minX,
                            y: observation.boundingBox.midY,
                            height: observation.boundingBox.height)
        }
        .sorted { left, right in
            if abs(left.y - right.y) < 0.002 { return left.x < right.x }
            return left.y > right.y
        }

        var rows: [Row] = []
        for fragment in fragments {
            if let last = rows.indices.last,
               abs(rows[last].y - fragment.y) <=
                    max(0.005, min(rows[last].height, fragment.height) * 0.46) {
                rows[last].fragments.append(fragment)
            } else {
                rows.append(Row(y: fragment.y,
                                height: fragment.height,
                                fragments: [fragment]))
            }
        }

        return rows.map { row in
            row.fragments.sorted { $0.x < $1.x }
                .map(\.text)
                .joined(separator: "   ")
        }.joined(separator: "\n")
    }
}
