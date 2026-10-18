import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct ReceiptMetadataSuggestion: Sendable {
    let category: String
    let tags: [String]
}

enum ReceiptMetadataSuggester {
    static func suggest(
        retailer: String,
        itemNames: [String],
        total: Decimal
    ) async -> ReceiptMetadataSuggestion? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *),
              SystemLanguageModel.default.availability == .available else {
            return nil
        }

        do {
            return try await suggestWithFoundationModels(
                retailer: retailer,
                itemNames: itemNames,
                total: total
            )
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    @Generable
    struct GeneratedMetadata: Sendable {
        @Guide(description: "A short broad shopping category, such as Electronics, Groceries, Clothing, Home, Health, or Dining.")
        var category: String

        @Guide(description: "Between zero and five short, useful receipt tags. Do not include the category itself.")
        var tags: [String]
    }

    @available(iOS 26.0, *)
    private static func suggestWithFoundationModels(
        retailer: String,
        itemNames: [String],
        total: Decimal
    ) async throws -> ReceiptMetadataSuggestion? {
        let session = LanguageModelSession {
            "You organise purchase receipts. Suggest only metadata supported by the supplied retailer and item names. Never invent products, events, warranties, or purposes. Use a concise category and up to five short tags. If evidence is weak, use General and few or no tags."
        }

        let items = itemNames.prefix(40).joined(separator: ", ")
        let prompt = """
        Suggest a category and tags for this receipt.
        Retailer: \(retailer)
        Items: \(items.isEmpty ? "No item names provided" : items)
        Total: \(total)
        Return a broad category and up to five concise tags. Do not repeat the retailer as a tag unless useful.
        """

        let response = try await session.respond(
            to: prompt,
            generating: GeneratedMetadata.self
        )
        let category = response.content.category.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = await UpdateReceiptMetadata.normalised(response.content.tags)
            .filter { $0.count <= 32 }
            .prefix(5)
        guard !category.isEmpty else { return nil }
        return ReceiptMetadataSuggestion(category: String(category.prefix(40)), tags: Array(tags))
    }
    #endif
}
