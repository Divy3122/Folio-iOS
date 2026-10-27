//
//  RetailerBrowserViewModel.swift
//  Folio
//
//  Created by Ziyan Nadeem on 27/10/2026.
//

import SwiftUI
import Observation

@MainActor @Observable
final class RetailerBrowserViewModel {
    struct LetterGroup: Identifiable {
        let letter: String
        let retailers: [SavedRetailer]
        var id: String { letter }
    }

    private(set) var retailers: [SavedRetailer] = []
    private(set) var hasLoaded = false
    var searchText = ""
    var errorMessage: String?

    var groups: [LetterGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? retailers : retailers.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let grouped = Dictionary(grouping: filtered) { Self.letter(for: $0.name) }
        let letters = grouped.keys.sorted { $0 == "#" ? false : $1 == "#" ? true : $0 < $1 }
        return letters.map { LetterGroup(letter: $0, retailers: grouped[$0] ?? []) }
    }

    private var manage: ManageRetailers? { ReceiptSavingContext.current?.services.manageRetailers }

    func retailer(id: UUID) -> SavedRetailer? { retailers.first { $0.id == id } }

    func load() async {
        guard let manage else { errorMessage = "Retailer storage isn't available."; return }
        do {
            retailers = try await manage.all()
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(_ retailer: SavedRetailer) async throws {
        guard let manage else { throw FolioError.persistenceFailure }
        try await manage.save(retailer)
        retailers = try await manage.all()
    }

    func delete(id: UUID) async throws {
        guard let manage else { throw FolioError.persistenceFailure }
        try await manage.delete(id: id)
        retailers = try await manage.all()
    }

    private static func letter(for name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }
}
