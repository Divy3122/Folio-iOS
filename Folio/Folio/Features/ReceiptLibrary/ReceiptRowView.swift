import SwiftUI

// MARK: - Expiry Status Calculator

enum ReceiptExpiryUrgency {
    case safe      // All policies healthy or no policies
    case warning   // At least one policy expiring soon (<= 7 days)
    case critical  // Policy expired or multiple policies expiring imminently

    var cardBackground: Color {
        switch self {
        case .safe:
            return Color.CardBackground
        case .warning:
            return Color.WarningAmber
        case .critical:
            return Color.ErrorRed
        }
    }
}

extension ReceiptRecord {
    /// Evaluates warranty and return deadlines relative to purchase date.
    var urgency: ReceiptExpiryUrgency {
        let now = Date.now
        let calendar = Calendar.current
        var deadlines: [Date] = []

        // Return policy deadline
        if let windowDays = receipt.returnPolicy?.windowDays,
           let deadline = calendar.date(byAdding: .day, value: windowDays, to: receipt.purchasedAt) {
            deadlines.append(deadline)
        }

        // Warranty & extra applied policies from metadata
        for policy in metadata.policies {
            if let deadline = calendar.date(byAdding: .day, value: policy.windowDays, to: receipt.purchasedAt) {
                deadlines.append(deadline)
            }
        }

        guard !deadlines.isEmpty else { return .safe }

        let expiredCount = deadlines.filter { $0 <= now }.count
        let expiringSoonCount = deadlines.filter { $0 > now && calendar.dateComponents([.day], from: now, to: $0).day ?? 0 <= 7 }.count

        if expiredCount > 0 {
            return .critical
        } else if expiringSoonCount > 0 {
            return .warning
        } else {
            return .safe
        }
    }

    /// Primary expiration badge summary text.
    var statusSummaryText: String {
        let now = Date.now
        let calendar = Calendar.current
        var parts: [String] = []

        if let windowDays = receipt.returnPolicy?.windowDays,
           let returnDate = calendar.date(byAdding: .day, value: windowDays, to: receipt.purchasedAt) {
            if returnDate <= now {
                parts.append("Return expired")
            } else {
                let days = calendar.dateComponents([.day], from: now, to: returnDate).day ?? 0
                parts.append("Return: \(days)d left")
            }
        }

        for policy in metadata.policies where policy.kind == .warranty {
            if let warrantyDate = calendar.date(byAdding: .day, value: policy.windowDays, to: receipt.purchasedAt) {
                if warrantyDate <= now {
                    parts.append("Warranty ended")
                } else {
                    let days = calendar.dateComponents([.day], from: now, to: warrantyDate).day ?? 0
                    parts.append("Warranty: \(days)d left")
                }
            }
        }

        return parts.isEmpty ? "No policies" : parts.joined(separator: " • ")
    }
}

// MARK: - Receipt Cube View (Square Aspect Ratio with Selection)

struct ReceiptCubeView: View {
    let record: ReceiptRecord
    var isSelecting: Bool = false
    var isSelected: Bool = false

    private var receipt: PurchaseReceipt { record.receipt }

    private var categoryText: String? {
        let clean = record.metadata.category.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: Retailer Avatar, Selection Checkmark & Purchase Date
            HStack(alignment: .center) {
                RetailerAvatar(name: receipt.retailer.name, size: 34)
                
                Spacer()
                
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.7))
                        .background(Circle().fill(Color.black.opacity(0.2)))
                } else {
                    Text(receipt.purchasedAt, format: .dateTime.day().month(.abbreviated))
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.white)
                }
            }

            Spacer(minLength: 4)

            // Content: Retailer Name, Category & Total
            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.retailer.name)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(Color.primary)

                if let category = categoryText {
                    Text(category)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }

                Text(receipt.total.formatted(.currency(code: receipt.currencyCode)))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
                    .padding(.top, 1)
            }

            Spacer(minLength: 4)

            // Footer: Expiry Indicator
            HStack(spacing: 4) {
                Image(systemName: record.urgency == .safe ? "shield.checkmark.fill" : "exclamationmark.triangle.fill")
                    .font(.caption2)

                Text(record.statusSummaryText)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(record.urgency == .safe ? Color.secondary : Color.white)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aspectRatio(1.0, contentMode: .fit)
        .background(record.urgency.cardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
        )
        .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 3)
        .accessibilityElement(children: .combine)
    }
}
