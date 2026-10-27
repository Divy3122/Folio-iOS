//
//  PolicyDraft.swift
//  Folio
//
//  Created by Ziyan Nadeem on 21/10/2026.
//

import Foundation

extension SavedRetailer {
    var defaultReturnPolicyID: UUID? {
        policies.filter { $0.kind == .returns }.min { $0.windowDays < $1.windowDays }?.id
    }

    var defaultWarrantyMonths: Int {
        policies.first { $0.kind == .warranty }.map { WarrantyLength.months(days: $0.windowDays) } ?? 0
    }
}

enum WarrantyLength {
    static let maxMonths = 120

    static func days(months: Int) -> Int {
        min(3650, Int((Double(months) * 365.25 / 12).rounded()))
    }

    static func months(days: Int) -> Int {
        guard days > 0 else { return 0 }
        return min(maxMonths, max(1, Int((Double(days) / 30.4375).rounded())))
    }

    static func describe(months: Int) -> String {
        guard months > 0 else { return "None" }
        let years = months / 12, rest = months % 12
        var parts: [String] = []
        if years > 0 { parts.append(years == 1 ? "1 year" : "\(years) years") }
        if rest > 0 { parts.append(rest == 1 ? "1 month" : "\(rest) months") }
        return parts.joined(separator: " ")
    }
}

struct PolicyDraft: Identifiable, Equatable {
    enum WarrantyUnit: String, CaseIterable, Identifiable {
        case days = "Days", months = "Months", years = "Years", lifetime = "Lifetime"

        var id: String { rawValue }

        var maximum: Int {
            switch self {
            case .days: return 3650
            case .months: return 120
            case .years: return 10
            case .lifetime: return 1
            }
        }
    }

    var id = UUID()
    var kind: SavedPolicy.Kind = .returns
    var title = ""
    var daysText = ""
    var notes = ""
    var applies = false
    var isConfirmed = false
    var isEditing = true
    var warrantyUnit: WarrantyUnit = .days
    var warrantyValue = 30

    // MARK: - Per-Policy Reminder Properties
    var setReminder = false
    var reminderDate = Date.now

    init() {}

    init(_ policy: SavedPolicy) {
        id = policy.id
        kind = policy.kind
        title = policy.title
        daysText = String(policy.windowDays)
        notes = policy.notes
        isConfirmed = true
        isEditing = false
        if policy.kind == .warranty {
            (warrantyValue, warrantyUnit) = Self.bestUnit(for: policy.windowDays)
        }
    }

    static func new(_ kind: SavedPolicy.Kind, applies: Bool) -> PolicyDraft {
        var draft = PolicyDraft()
        draft.kind = kind
        draft.applies = applies
        draft.title = kind == .returns ? "Return policy" : "Warranty"
        if kind == .returns {
            draft.daysText = "30"
        } else {
            draft.warrantyValue = 12
            draft.warrantyUnit = .months
        }
        return draft
    }

    func deadline(from purchaseDate: Date) -> Date? {
        guard let window = days else { return nil }
        return Calendar.current.date(byAdding: .day, value: window, to: purchaseDate)
    }

    private static func bestUnit(for days: Int) -> (Int, WarrantyUnit) {
        if days >= 36500 { return (1, .lifetime) }
        if days % 365 == 0, days / 365 <= 10 { return (days / 365, .years) }
        let months = WarrantyLength.months(days: days)
        return WarrantyLength.days(months: months) == days ? (months, .months) : (days, .days)
    }

    var days: Int? {
        if kind == .warranty {
            if warrantyUnit == .lifetime { return 36500 }
            guard (1...warrantyUnit.maximum).contains(warrantyValue) else { return nil }
            switch warrantyUnit {
            case .days: return warrantyValue
            case .months: return WarrantyLength.days(months: warrantyValue)
            case .years: return warrantyValue * 365
            case .lifetime: return 36500
            }
        }
        guard let value = Int(daysText.trimmingCharacters(in: .whitespaces)), (1...3650).contains(value) else { return nil }
        return value
    }

    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanNotes: String { notes.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isValid: Bool { !cleanTitle.isEmpty && days != nil }

    var durationText: String {
        guard let days else { return "" }
        if kind == .returns { return "\(days) day\(days == 1 ? "" : "s") to return" }
        if warrantyUnit == .lifetime || days >= 36500 { return "Lifetime warranty" }
        let unit = warrantyUnit.rawValue.lowercased()
        return "\(warrantyValue) \(warrantyValue == 1 ? String(unit.dropLast()) : unit) warranty"
    }

    var saved: SavedPolicy? {
        days.map { SavedPolicy(id: id, kind: kind, title: cleanTitle, windowDays: $0, notes: cleanNotes) }
    }

    var applied: AppliedPolicy? {
        days.map { AppliedPolicy(kind: kind, title: cleanTitle, windowDays: $0, notes: cleanNotes, sourcePolicyID: id) }
    }
}

extension SavedPolicy.Kind {
    var label: String { self == .returns ? "Return" : "Warranty" }
}
