import Foundation

enum FolioError: Error, Equatable, LocalizedError, Sendable {
    case invalidReceipt
    case invalidDateRange
    case invalidReturnPolicy
    case invalidReminderDate
    case receiptNotFound
    case persistenceFailure
    case extractionUnavailable
    case notificationsUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidReceipt: "Check the retailer, currency, amounts and item quantities."
        case .invalidDateRange: "The end date must be later than the start date."
        case .invalidReturnPolicy: "Confirm a valid retailer return policy first."
        case .invalidReminderDate: "Choose a future reminder no later than the return deadline."
        case .receiptNotFound: "Save the receipt before creating a reminder."
        case .persistenceFailure: "Your local data could not be loaded or saved. Please try again."
        case .extractionUnavailable: "Automatic extraction is unavailable. Review the receipt manually."
        case .notificationsUnavailable: "Notifications are unavailable. Your saved reminders remain in Folio."
        }
    }
}
