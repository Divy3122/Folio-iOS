import Foundation

protocol ReceiptImageStore {
    func save(_ pages: [Data], for receiptID: UUID) throws -> Int
    func loadPage(_ index: Int, for receiptID: UUID) throws -> Data?
    func delete(receiptID: UUID) throws
}

struct FileReceiptImageStore: ReceiptImageStore {
    private let root: URL

    static func makeDefault() throws -> FileReceiptImageStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try FileReceiptImageStore(root: support.appendingPathComponent("ReceiptImages", isDirectory: true))
    }

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try mutableRoot.setResourceValues(values)
    }

    func save(_ pages: [Data], for receiptID: UUID) throws -> Int {
        let fm = FileManager.default
        let destination = directory(for: receiptID)
        let staging = root.appendingPathComponent("\(receiptID.uuidString).staging", isDirectory: true)
        do {
            if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for (index, data) in pages.enumerated() {
                try data.write(to: staging.appendingPathComponent(fileName(index)),
                               options: [.completeFileProtectionUntilFirstUserAuthentication])
            }
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: staging, to: destination)
            return pages.count
        } catch {
            try? fm.removeItem(at: staging)
            throw FolioError.persistenceFailure
        }
    }

    func loadPage(_ index: Int, for receiptID: UUID) throws -> Data? {
        let url = directory(for: receiptID).appendingPathComponent(fileName(index))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try Data(contentsOf: url) }
        catch { throw FolioError.persistenceFailure }
    }

    func delete(receiptID: UUID) throws {
        let url = directory(for: receiptID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { throw FolioError.persistenceFailure }
    }

    private func directory(for receiptID: UUID) -> URL {
        root.appendingPathComponent(receiptID.uuidString, isDirectory: true)
    }

    private func fileName(_ index: Int) -> String { "page-\(index).jpg" }
}
