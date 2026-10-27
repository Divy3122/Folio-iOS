import Foundation

/// A single local review draft, including untouched camera JPEGs.
/// Never stores or logs receipt data remotely.
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

    init(url: URL) {
        self.url = url
    }

    static func live() -> ReceiptScannerDraftStore {
        let directory = URL.applicationSupportDirectory
            .appending(path: "ReceiptScanner", directoryHint: .isDirectory)

        return ReceiptScannerDraftStore(
            url: directory.appending(path: "review.json")
        )
    }

    func load() throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)

        guard snapshot.version == 1 else {
            throw FolioError.persistenceFailure
        }

        return snapshot
    }

    func save(_ snapshot: Snapshot) throws {
        let directory = url.deletingLastPathComponent()

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var excludedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true

        try excludedDirectory.setResourceValues(values)

        let data = try JSONEncoder().encode(snapshot)

        try data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    func clear() throws {
        // Remove the same file that save(_:) writes and load() reads.
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        try FileManager.default.removeItem(at: url)
    }
}
