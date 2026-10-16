//
//  ReceiptScannerViewModel.swift
//  Folio
//
//  Created by Divy Patel on 16/10/2026.
//


import Foundation
import Observation

@MainActor
@Observable
final class ReceiptScannerViewModel {
    var extractedText = ""
    var pageCount = 0
    var isProcessing = false
    var errorMessage: String?

    private let recognizer: any ReceiptTextRecognizing

    init(
        recognizer: any ReceiptTextRecognizing = VisionReceiptTextRecognizer()
    ) {
        self.recognizer = recognizer
    }


    func process(pages: [Data]) async {
        guard !isProcessing else { return }

        isProcessing = true
        extractedText = ""
        errorMessage = nil
        pageCount = pages.count

        defer {
            isProcessing = false
        }

        do {
            guard !pages.isEmpty else {
                throw ScannerError.noPages
            }

            var recognisedPages: [String] = []

            for (index, page) in pages.enumerated() {
                try Task.checkCancellation()

                let text = try await recognizer.recognize(
                    imageData: page
                )

                if !text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty {
                    recognisedPages.append(
                        "Page \(index + 1)\n\(text)"
                    )
                }
            }

            guard !recognisedPages.isEmpty else {
                throw ScannerError.noReadableText
            }

            extractedText = recognisedPages.joined(
                separator: "\n\n"
            )

        } catch {
            errorMessage = error.localizedDescription
        }
    }


    func reportError(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    func reportUnsupportedCamera() {
        errorMessage = "Document scanning is not available on this device."
    }
}
