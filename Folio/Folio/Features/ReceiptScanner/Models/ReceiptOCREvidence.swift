import Foundation

/// Normalised Apple Vision coordinates (0...1, origin at the image's lower-left).
/// These are location hints, not crop-accurate character rectangles.
struct ReceiptOCRBox: Codable, Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var midY: Double { y + height / 2 }
    var minX: Double { x }

    static func enclosing(_ boxes: [ReceiptOCRBox]) -> ReceiptOCRBox? {
        guard let first = boxes.first else { return nil }
        let left = boxes.map(\.x).min() ?? first.x
        let bottom = boxes.map(\.y).min() ?? first.y
        let right = boxes.map { $0.x + $0.width }.max() ?? first.x + first.width
        let top = boxes.map { $0.y + $0.height }.max() ?? first.y + first.height
        return ReceiptOCRBox(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}

/// A candidate string proposed by Vision, not independently verified text.
struct ReceiptOCRCandidate: Codable, Sendable, Equatable {
    let text: String
    let confidence: Double
}

/// One Vision text observation and its ranked candidate strings.
struct ReceiptOCRFragment: Codable, Sendable, Equatable {
    let box: ReceiptOCRBox
    let candidates: [ReceiptOCRCandidate]

    var text: String { candidates.first?.text ?? "" }
    var confidence: Double { candidates.first?.confidence ?? 0 }
    var alternatives: [ReceiptOCRCandidate] { Array(candidates.dropFirst()) }
}

/// Fragments ordered left-to-right, grouped at approximately the same page height.
struct ReceiptOCRLine: Codable, Sendable, Equatable {
    let fragments: [ReceiptOCRFragment]

    var text: String { fragments.map(\.text).joined(separator: "   ") }
    var box: ReceiptOCRBox? { ReceiptOCRBox.enclosing(fragments.map(\.box)) }
    var minimumConfidence: Double { fragments.map(\.confidence).min() ?? 0 }
}

/// All OCR evidence for one page. Original image bytes stay in Folio's draft store.
struct ReceiptOCRPage: Codable, Sendable, Equatable {
    let pageNumber: Int
    let lines: [ReceiptOCRLine]

    var text: String { lines.map(\.text).joined(separator: "\n") }
}

/// An additive capability: existing shared ReceiptTextRecognizing stays unchanged.
protocol ReceiptEvidenceRecognizing: ReceiptTextRecognizing {
    func recognizeEvidence(imageData: Data) async throws -> ReceiptOCRPage
}

/// Allows production extraction to consume evidence while old mocks still use text.
protocol ReceiptEvidenceExtracting: ReceiptExtracting {
    func extract(text: String, evidence: [ReceiptOCRPage]) async throws -> ReceiptExtractionResult
}

/// Pure Swift row reconstruction, independently testable without VisionKit/camera.
enum ReceiptOCRLayout {
    static func lines(from fragments: [ReceiptOCRFragment]) -> [ReceiptOCRLine] {
        let ordered = fragments.filter { !$0.text.isEmpty }.sorted { lhs, rhs in
            if abs(lhs.box.midY - rhs.box.midY) < 0.002 {
                return lhs.box.minX < rhs.box.minX
            }
            return lhs.box.midY > rhs.box.midY
        }
        var groups: [[ReceiptOCRFragment]] = []
        for fragment in ordered {
            if let last = groups.indices.last,
               let anchor = groups[last].first,
               abs(anchor.box.midY - fragment.box.midY) <= max(
                   0.005,
                   min(anchor.box.height, fragment.box.height) * 0.46
               ) {
                groups[last].append(fragment)
            } else {
                groups.append([fragment])
            }
        }
        return groups.map { group in
            ReceiptOCRLine(fragments: group.sorted { $0.box.minX < $1.box.minX })
        }
    }
}

/// Produces page-stable line references matching the raw text used by the mapper.
/// Alternatives are advisory only; they never replace the original OCR source.
enum ReceiptOCREvidencePrompt {
    static func renderedText(pages: [ReceiptOCRPage]) -> String {
        pages.map { "Page \($0.pageNumber)\n\($0.text)" }
            .joined(separator: "\n\n")
    }

    /// Only returns annotations for an exact text/evidence pairing; stale drafts
    /// and partial page failures must never associate the wrong source lines.
    static func focusedContext(
        numberedOCR: String,
        chunkStartLine: Int,
        chunkLines: [String],
        originalText: String,
        pages: [ReceiptOCRPage]
    ) -> String {
        guard !pages.isEmpty, renderedText(pages: pages) == originalText else {
            return numberedOCR
        }
        var annotations: [(priority: Int, order: Int, text: String)] = []
        var globalLine = 1
        for (pageIndex, page) in pages.enumerated() {
            globalLine += 1 // "Page N"
            for line in page.lines {
                if globalLine >= chunkStartLine && globalLine < chunkStartLine + chunkLines.count {
                    let offset = globalLine - chunkStartLine
                    if line.text == chunkLines[offset] {
                        for fragment in line.fragments {
                            let alternatives = fragment.alternatives
                                .filter { $0.text != fragment.text }
                                .prefix(2)
                            let alternativesText = alternatives.map {
                                "'\($0.text)' (confidence \(String(format: "%.2f", $0.confidence)))"
                            }.joined(separator: ", ")
                            // Only surface uncertainty, and never present a candidate as fact.
                            if fragment.confidence < 0.85 || !alternativesText.isEmpty {
                                let box = fragment.box
                                // Monetary ambiguity is more useful than ordinary
                                // spelling ambiguity. Limit annotations so a long
                                // receipt cannot overwhelm the focused AI request.
                                let amountPattern = #"[0-9][.,][0-9]{2}"#
                                let isMonetary = ([fragment.text] + alternatives.map(\.text))
                                    .contains { $0.range(of: amountPattern, options: .regularExpression) != nil }
                                annotations.append((
                                    priority: isMonetary ? 0 : 1,
                                    order: annotations.count,
                                    text: "Line \(globalLine), x=\(String(format: "%.3f", box.x)), " +
                                        "y=\(String(format: "%.3f", box.y)): " +
                                        "'\(fragment.text)' confidence \(String(format: "%.2f", fragment.confidence))" +
                                        (alternativesText.isEmpty ? "" : "; possible alternatives: \(alternativesText)")
                                ))
                            }
                        }
                    }
                }
                globalLine += 1
            }
            if pageIndex < pages.count - 1 { globalLine += 1 } // blank separator line
        }
        guard !annotations.isEmpty else { return numberedOCR }
        let selected = annotations.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.order < $1.order
        }.prefix(16)
        return numberedOCR + "\n\nVISION OCR UNCERTAINTY (not verified; don't substitute candidates as facts):\n" +
            selected.map(\.text).joined(separator: "\n")
    }
}
