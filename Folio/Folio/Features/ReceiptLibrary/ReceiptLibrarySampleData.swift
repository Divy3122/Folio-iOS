#if DEBUG
import SwiftData
import SwiftUI
import UIKit

@MainActor enum ReceiptLibrarySampleData {
    static func seed(into services: ReceiptLibraryServices) async throws {
        for sample in samples() {
            var record = sample.record
            if sample.pages > 0 {
                let pages = (1...sample.pages).map { placeholderPage(title: record.receipt.retailer.name, number: $0) }
                record.metadata.imageCount = try services.images.save(pages, for: record.id)
            }
            try await services.repository.save(record)
        }
    }

    private static func decimal(_ text: String) -> Decimal { Decimal(string: text) ?? 0 }

    private static func make(
        _ number: Int, _ retailer: String, daysAgo: Int, total: String,
        items: [(String, Int, String)], profile: PurchaseProfile = .personal,
        category: String = "", tags: [String] = [], notes: String = "", pages: Int = 0
    ) -> (record: ReceiptRecord, pages: Int) {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID()
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        let receipt = PurchaseReceipt(
            id: id, retailer: Retailer(name: retailer), purchasedAt: date, currencyCode: "AUD",
            total: decimal(total),
            items: items.map { PurchasedItem(name: $0.0, quantity: $0.1, unitPrice: decimal($0.2)) },
            profile: profile)
        var record = ReceiptRecord(receipt: receipt)
        record.metadata.category = category
        record.metadata.tags = tags
        record.metadata.notes = notes
        return (record, pages)
    }

    private static func samples() -> [(record: ReceiptRecord, pages: Int)] {
        [
            make(1, "JB Hi-Fi", daysAgo: 1_095, total: "199.00",
                 items: [("JBL Tune 510BT Headphones", 1, "199.00")],
                 category: "Electronics", tags: ["warranty", "headphones"], pages: 2),
            make(2, "Woolworths", daysAgo: 2, total: "86.40",
                 items: [("Milk 2L", 2, "3.20"), ("Sourdough loaf", 1, "6.50"), ("Chicken breast", 1, "13.50")],
                 category: "Groceries"),
            make(3, "Bunnings", daysAgo: 12, total: "245.90",
                 items: [("Cordless drill", 1, "199.00"), ("Drill bit set", 1, "46.90")],
                 profile: .business, category: "Tools", tags: ["tax"], notes: "Workshop equipment", pages: 1),
            make(4, "Officeworks", daysAgo: 40, total: "64.95",
                 items: [("A4 paper", 3, "9.65"), ("Printer ink", 1, "36.00")],
                 profile: .business, category: "Office"),
            make(5, "Kmart", daysAgo: 75, total: "42.00",
                 items: [("Desk lamp", 1, "25.00"), ("Storage box", 2, "8.50")],
                 category: "Home"),
            make(6, "Apple Store", daysAgo: 400, total: "1299.00",
                 items: [("MacBook Air", 1, "1299.00")],
                 category: "Electronics", tags: ["warranty"], pages: 1)
        ]
    }

    private static func placeholderPage(title: String, number: Int) -> Data {
        let size = CGSize(width: 600, height: 900)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let text = "\(title)\nSample receipt, page \(number)" as NSString
            text.draw(in: CGRect(x: 40, y: 40, width: 520, height: 200), withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 32, weight: .regular),
                .foregroundColor: UIColor.black
            ])
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }
}

private struct ReceiptLibraryPreviewHost: View {
    @State private var services: ReceiptLibraryServices?

    var body: some View {
        Group {
            if let services {
                ReceiptLibraryView(services: services)
            } else {
                ProgressView()
            }
        }
        .task { services = try? await Self.makeSeededServices() }
    }

    private static func makeSeededServices() async throws -> ReceiptLibraryServices {
        let container = try ModelContainer(
            for: StoredReceipt.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceiptLibraryPreview-\(UUID().uuidString)")
        let services = ReceiptLibraryServices(
            repository: SwiftDataReceiptRepository(container: container),
            images: try FileReceiptImageStore(root: folder))
        try await ReceiptLibrarySampleData.seed(into: services)
        return services
    }
}

#Preview("Receipt library") {
    ReceiptLibraryPreviewHost()
}
#endif
