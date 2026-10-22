import SwiftUI
import UIKit

// MARK: - Identifiable Image Wrapper for Sheet Presentation

struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ReceiptDetailView: View {
    let services: ReceiptLibraryServices
    
    @State private var currentRecord: ReceiptRecord
    @Environment(\.dismiss) private var dismiss
    
    // Scanned Images State
    @State private var loadedImages: [UIImage] = []
    @State private var selectedPreviewImage: IdentifiableImage?
    @State private var imageLoadFailed = false
    
    // Scheduled Reminders Tracking for Display
    @State private var activeReminders: [UUID: ReturnReminder] = [:]
    
    // Edit & Delete Actions State
    @State private var isEditing = false
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false

    init(record: ReceiptRecord, services: ReceiptLibraryServices) {
        self._currentRecord = State(initialValue: record)
        self.services = services
    }

    private var receipt: PurchaseReceipt { currentRecord.receipt }

    private var formattedTotal: String {
        receipt.total.formatted(.currency(code: receipt.currencyCode))
    }

    private var costRows: [(label: String, value: Decimal)] {
        guard let costs = currentRecord.costs else { return [] }
        let rows: [(String, Decimal?)] = [
            ("Subtotal", costs.subtotal),
            ("Discounts", costs.discounts),
            ("Tax / GST", costs.tax),
            ("Fees", costs.fees),
            ("Rounding", costs.rounding)
        ]
        return rows.compactMap { label, value in
            guard let val = value, val != 0 else { return nil }
            return (label, val)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // MARK: - 1. Hero Summary Card
                heroHeaderCard

                // MARK: - 2. Policy & Warranty Status Cards
                if hasActivePolicies {
                    policyStatusSection
                }

                // MARK: - 3. Purchased Items
                if !receipt.items.isEmpty {
                    itemsSection
                }

                // MARK: - 4. Cost Breakdown
                if !costRows.isEmpty {
                    costBreakdownSection
                }

                // MARK: - 5. Scanned Receipt Gallery
                if currentRecord.metadata.imageCount > 0 {
                    scannedDocumentSection
                }

                // MARK: - 6. Metadata & Notes
                metadataAndNotesSection
                
                // MARK: - Delete Action Button
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete Receipt", systemImage: "trash")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.ErrorRed.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(Color.ErrorRed)
                }
                .padding(.top, 8)
                .disabled(isDeleting)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(receipt.retailer.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let firstImage = loadedImages.first {
                    ShareLink(
                        item: Image(uiImage: firstImage),
                        preview: SharePreview("\(receipt.retailer.name) Receipt", image: Image(uiImage: firstImage))
                    ) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.BrandTeal)
                    }
                }

                Button("Edit") {
                    isEditing = true
                }
                .font(.body.weight(.bold))
                .foregroundStyle(Color.BrandTeal)
            }
        }
        .sheet(isPresented: $isEditing, onDismiss: {
            Task { await refreshRecordAndReminders() }
        }) {
            ReceiptSaveSheet(
                costs: currentRecord.costs ?? ReceiptCostBreakdown(products: [], total: receipt.total),
                pages: [],
                existingRecord: currentRecord
            )
        }
        .sheet(item: $selectedPreviewImage) { item in
            FullScreenImageViewer(image: item.image)
        }
        .confirmationDialog(
            "Delete receipt from \(receipt.retailer.name)?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Receipt", role: .destructive) {
                Task { await deleteReceipt() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove this receipt and its scanned images. This action cannot be undone.")
        }
        .task {
            loadScannedImages()
            await fetchExistingReminders()
        }
    }

    // MARK: - Hero Header Card

    private var heroHeaderCard: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top) {
                RetailerAvatar(name: receipt.retailer.name, size: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(receipt.retailer.name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color.primary)

                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                        Text(receipt.purchasedAt, format: .dateTime.day().month().year())
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                }

                Spacer()

                Text(receipt.profile.rawValue.capitalized)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.BrandTeal.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.BrandTeal)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total Amount")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                    Text(formattedTotal)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primary)
                }

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: currentRecord.urgency == .safe ? "shield.checkmark.fill" : "exclamationmark.triangle.fill")
                    Text(currentRecord.statusSummaryText)
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(urgencyColor(currentRecord.urgency), in: Capsule())
                .foregroundStyle(.white)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func urgencyColor(_ urgency: ReceiptExpiryUrgency) -> Color {
        switch urgency {
        case .safe: return Color.BrandTeal
        case .warning: return Color.WarningAmber
        case .critical: return Color.ErrorRed
        }
    }

    // MARK: - Policy Status Section

    private var hasActivePolicies: Bool {
        receipt.returnPolicy != nil || !currentRecord.metadata.policies.isEmpty
    }

    private var policyStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Policies & Coverage")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                Spacer()
                Button("Edit Policies") {
                    isEditing = true
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.BrandTeal)
            }

            VStack(spacing: 10) {
                if let returnPolicy = receipt.returnPolicy,
                   !currentRecord.metadata.policies.contains(where: { $0.kind == .returns }) {
                    let deadline = Calendar.current.date(byAdding: .day, value: returnPolicy.windowDays, to: receipt.purchasedAt)
                    let key = currentRecord.id

                    PolicyDetailRow(
                        title: "Return Window",
                        subtitle: "\(returnPolicy.windowDays) Days Standard Policy",
                        deadline: deadline,
                        icon: "arrow.uturn.backward.circle.fill",
                        hasReminder: activeReminders[key] != nil
                    )
                }

                ForEach(currentRecord.metadata.policies) { policy in
                    let deadline = Calendar.current.date(byAdding: .day, value: policy.windowDays, to: receipt.purchasedAt)
                    let key = policy.id

                    PolicyDetailRow(
                        title: policy.title,
                        subtitle: policy.kind == .warranty ? "Warranty Protection" : "\(policy.windowDays) Days Return Policy",
                        deadline: deadline,
                        icon: policy.kind == .warranty ? "checkmark.shield.fill" : "arrow.uturn.backward.circle.fill",
                        hasReminder: activeReminders[key] != nil
                    )
                }
            }
        }
    }

    // MARK: - Scanned Document Section

    private var scannedDocumentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scanned Receipt")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                Spacer()
                Text("\(currentRecord.metadata.imageCount) \(currentRecord.metadata.imageCount == 1 ? "page" : "pages")")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            if !loadedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(loadedImages.enumerated()), id: \.offset) { index, image in
                            Button {
                                selectedPreviewImage = IdentifiableImage(image: image)
                            } label: {
                                ZStack(alignment: .bottomTrailing) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 130, height: 170)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                                        )

                                    Text("Page \(index + 1)")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.black.opacity(0.65), in: Capsule())
                                        .foregroundStyle(.white)
                                        .padding(8)
                                }
                            }
                        }
                    }
                }
            } else if imageLoadFailed {
                Label("Scanned receipt file unavailable.", systemImage: "photo.badge.exclamationmark")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            } else {
                ProgressView("Loading scans…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    // MARK: - Purchased Items Section

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Purchased Items")
                .font(.headline)
                .foregroundStyle(Color.primary)

            VStack(spacing: 0) {
                ForEach(Array(receipt.items.enumerated()), id: \.element.id) { index, item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.primary)

                            if item.quantity > 1 {
                                Text("\(item.quantity) × \(item.unitPrice.formatted(.currency(code: receipt.currencyCode))) each")
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                            }
                        }

                        Spacer()

                        Text((item.unitPrice * Decimal(item.quantity)).formatted(.currency(code: receipt.currencyCode)))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.primary)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)

                    if index < receipt.items.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    // MARK: - Cost Breakdown Section

    private var costBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cost Breakdown")
                .font(.headline)
                .foregroundStyle(Color.primary)

            VStack(spacing: 8) {
                ForEach(costRows, id: \.label) { row in
                    HStack {
                        Text(row.label)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                        Spacer()
                        Text(row.value.formatted(.currency(code: receipt.currencyCode)))
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.primary)
                    }
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    // MARK: - Metadata & Notes Section

    private var metadataAndNotesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details & Notes")
                .font(.headline)
                .foregroundStyle(Color.primary)

            VStack(alignment: .leading, spacing: 14) {
                if !currentRecord.metadata.category.isEmpty {
                    HStack {
                        Label("Category", systemImage: "folder")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                        Spacer()
                        Text(currentRecord.metadata.category)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                    }
                }

                if !currentRecord.metadata.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Notes", systemImage: "note.text")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)

                        Text(currentRecord.metadata.notes)
                            .font(.subheadline)
                            .foregroundStyle(Color.primary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    // MARK: - Data Refresh & Storage Helpers

    private func fetchExistingReminders() async {
        guard let reminderRepo = services.reminders else { return }
        if let all = try? await reminderRepo.fetchAll() {
            var map: [UUID: ReturnReminder] = [:]
            let matching = all.filter { $0.receiptID == currentRecord.id }
            for r in matching {
                map[r.id] = r
            }
            activeReminders = map
        }
    }

    private func refreshRecordAndReminders() async {
        if let updated = try? await services.repository.fetchRecord(id: currentRecord.id) {
            currentRecord = updated
        }
        await fetchExistingReminders()
    }

    private func loadScannedImages() {
        guard currentRecord.metadata.imageCount > 0 else { return }
        var images: [UIImage] = []

        for index in 0..<currentRecord.metadata.imageCount {
            if let data = try? services.images.loadPage(index, for: currentRecord.id),
               let image = UIImage(data: data) {
                images.append(image)
            }
        }

        if !images.isEmpty {
            loadedImages = images
        } else {
            imageLoadFailed = true
        }
    }

    private func deleteReceipt() async {
        isDeleting = true
        defer { isDeleting = false }

        let useCase = DeleteReceipt(
            repository: services.repository,
            images: services.images,
            reminders: services.reminders,
            scheduler: services.scheduler
        )

        do {
            try await useCase(id: currentRecord.id)
            dismiss()
        } catch {
            print("Failed to delete receipt: \(error.localizedDescription)")
        }
    }
}

// MARK: - Read-Only Policy Detail Row Component

private struct PolicyDetailRow: View {
    let title: String
    let subtitle: String
    let deadline: Date?
    let icon: String
    let hasReminder: Bool

    private var isExpired: Bool {
        guard let deadline else { return false }
        return deadline <= Date.now
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isExpired ? Color.ErrorRed : Color.BrandTeal)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }

                Spacer()

                if let deadline {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(isExpired ? "Expired" : "Expires")
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                        Text(deadline, format: .dateTime.day().month(.abbreviated).year())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isExpired ? Color.ErrorRed : Color.primary)
                    }
                }
            }

            if hasReminder && !isExpired {
                Divider()

                HStack {
                    Label("Reminder Active", systemImage: "bell.badge.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.BrandTeal)
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Full Screen Image Viewer Modal

private struct FullScreenImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("Scanned Receipt", image: Image(uiImage: image))) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }
}
