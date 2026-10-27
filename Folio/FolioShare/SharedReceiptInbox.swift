//
//  SharedReceiptInbox.swift
//  Folio
//
//  Created by Ziyan Nadeem on 27/10/2026.
//

import Foundation
import ImageIO
import UIKit

enum SharedReceiptInbox {
    /// Must match the App Group on BOTH targets.
    nonisolated static let appGroupID = "group.com.uts.edu.Folio"

    enum InboxError: Error { case appGroupUnavailable }

    nonisolated private static var inboxURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("ReceiptInbox", isDirectory: true)
    }

    /// Writes pages into a hidden temp folder, then renames it, so the app
    /// never reads a half-written batch.
    @discardableResult
    nonisolated static func save(pages: [Data]) throws -> URL {
        guard let inbox = inboxURL else { throw InboxError.appGroupUnavailable }
        let fm = FileManager.default
        let id = UUID().uuidString
        let temp = inbox.appendingPathComponent(".incoming-\(id)", isDirectory: true)
        let final = inbox.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        for (index, data) in pages.enumerated() {
            try data.write(to: temp.appendingPathComponent(String(format: "%03d.jpg", index)),
                           options: .atomic)
        }
        try fm.moveItem(at: temp, to: final)
        return final
    }

    /// Oldest first.
    nonisolated static func pendingBatches() -> [URL] {
        guard let inbox = inboxURL else { return [] }
        let keys: [URLResourceKey] = [.creationDateKey, .isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return a < b
            }
    }

    nonisolated static func pages(in batch: URL) -> [Data] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: batch, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? Data(contentsOf: $0) }
    }

    nonisolated static func remove(_ batch: URL) {
        try? FileManager.default.removeItem(at: batch)
    }

    /// Memory-safe: ImageIO decodes straight to a downsampled bitmap (extensions have ~120 MB).
    /// Handles HEIC/PNG and bakes in orientation.
    nonisolated static func normalizedJPEG(from data: Data, maxDimension: Int = 3000) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? maxDimension
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? maxDimension
        let target = min(maxDimension, max(width, height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: target
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95)
    }
}
