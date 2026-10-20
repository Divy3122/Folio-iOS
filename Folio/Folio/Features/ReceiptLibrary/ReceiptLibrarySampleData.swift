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
        _ number: Int,
        _ retailer: String,
        daysAgo: Int,
        total: String,
        items: [(String, Int, String)],
        profile: PurchaseProfile = .personal,
        category: String = "",
        tags: [String] = [],
        notes: String = "",
        returnDays: Int? = nil,
        policies: [AppliedPolicy] = [],
        pages: Int = 0
    ) -> (record: ReceiptRecord, pages: Int) {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID()
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        let returnPolicy = returnDays.map { ReturnPolicy(windowDays: $0, notes: "") }
        
        let receipt = PurchaseReceipt(
            id: id,
            retailer: Retailer(name: retailer),
            purchasedAt: date,
            currencyCode: "AUD",
            total: decimal(total),
            items: items.map { PurchasedItem(name: $0.0, quantity: $0.1, unitPrice: decimal($0.2)) },
            profile: profile,
            returnPolicy: returnPolicy
        )
        
        var record = ReceiptRecord(receipt: receipt)
        record.metadata.category = category
        record.metadata.tags = tags
        record.metadata.notes = notes
        record.metadata.policies = policies
        return (record, pages)
    }

    private static func samples() -> [(record: ReceiptRecord, pages: Int)] {
        [
            // 1. Safe (BrandTeal): Active Return Policy (25 days remaining) + Manufacturer Warranty
            make(
                1, "Apple Store", daysAgo: 5, total: "1899.00",
                items: [("iPhone 16 Pro", 1, "1899.00")],
                category: "Electronics", tags: ["tech", "warranty"],
                returnDays: 30,
                policies: [
                    AppliedPolicy(kind: .warranty, title: "AppleCare+", windowDays: 730)
                ],
                pages: 1
            ),

            // 2. Warning (WarningAmber): Expiring Soon (3 days remaining on return window)
            make(
                2, "JB Hi-Fi", daysAgo: 27, total: "249.00",
                items: [("Sony WH-CH720N Headphones", 1, "249.00")],
                category: "Audio", tags: ["headphones"],
                returnDays: 30,
                policies: [
                    AppliedPolicy(kind: .returns, title: "Standard Returns", windowDays: 30)
                ],
                pages: 1
            ),

            // 3. Critical (ErrorRed): Return Policy Window Expired (Expired 10 days ago)
            make(
                3, "Kmart", daysAgo: 40, total: "65.00",
                items: [("Air Fryer 5L", 1, "65.00")],
                category: "Home Appliances", tags: ["kitchen"],
                returnDays: 30,
                policies: [
                    AppliedPolicy(kind: .returns, title: "Change of Mind", windowDays: 30)
                ]
            ),

            // 4. Safe (BrandTeal): Groceries with no policies
            make(
                4, "Woolworths", daysAgo: 2, total: "94.20",
                items: [("Sourdough Bread", 1, "6.50"), ("Free Range Eggs 12pk", 2, "5.80"), ("Ribeye Steak", 1, "24.50")],
                category: "Groceries", tags: ["food"]
            ),

            // 5. Business Purchase: Tools with Active Commercial Warranty
            make(
                5, "Bunnings", daysAgo: 14, total: "329.00",
                items: [("DeWalt 18V Brushless Drill Kit", 1, "329.00")],
                profile: .business, category: "Tools & Hardware", tags: ["tax", "workshop"], notes: "Site equipment",
                returnDays: 90,
                policies: [
                    AppliedPolicy(kind: .warranty, title: "Trade Warranty", windowDays: 1095)
                ],
                pages: 2
            ),

            // 6. Business Purchase: Office Supplies
            make(
                6, "Officeworks", daysAgo: 12, total: "148.50",
                items: [("Refillable Ink Cartridge 4pk", 1, "112.00"), ("A4 Copy Paper 5pk", 1, "36.50")],
                profile: .business, category: "Office Supplies", tags: ["tax", "stationery"],
                returnDays: 30
            )
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
