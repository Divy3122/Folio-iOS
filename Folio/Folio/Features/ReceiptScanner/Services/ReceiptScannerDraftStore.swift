import Foundation

/// A single local review draft, including untouched camera JPEGs. Never stores or logs receipt data remotely.
actor ReceiptScannerDraftStore {
    struct Snapshot: Codable, Sendable {
        var version = 1
        var rawText: String
        var pages: [Data]
        var review: ReceiptReviewDraft
        var extractionWarnings: [String]
        /// Optional for backward-compatible decoding of existing version-1 drafts.
        var ocrEvidence: [ReceiptOCRPage]? = nil
        var company: CompanyReview? = nil
    }

    private let url: URL
    init(url: URL) { self.url = url }
    static func live() -> ReceiptScannerDraftStore {
        let directory = URL.applicationSupportDirectory.appending(path: "ReceiptScanner", directoryHint: .isDirectory)
        return ReceiptScannerDraftStore(url: directory.appending(path: "review.json"))
    }
    func load() throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == 1 else { throw FolioError.persistenceFailure }
        return snapshot
    }
    func save(_ snapshot: Snapshot) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excludedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedDirectory.setResourceValues(values)
        try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
