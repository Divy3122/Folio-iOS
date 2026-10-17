//
//  SampleReturnPolicies.swift
//  Folio
//
//  Created by Brandon Hua on 16/10/2026.
//

import Foundation

/// An example change-of-mind policy the user can pick and then confirm.
/// These are samples only — not statements of a retailer's actual policy or the user's legal rights.
struct RetailerPolicyTemplate: Identifiable, Equatable, Sendable {
    var id: String { retailerName }
    let retailerName: String
    let windowDays: Int
    let notes: String

    /// Turns the template into the shared ReturnPolicy model saved on a receipt.
    var returnPolicy: ReturnPolicy {
        ReturnPolicy(windowDays: windowDays, notes: notes)
    }
}

enum SampleReturnPolicies {
    /// The list shown in the policy picker. All windows are samples, not real store policies.
    static let all: [RetailerPolicyTemplate] = [
        RetailerPolicyTemplate(
            retailerName: "JB Hi-Fi",
            windowDays: 14,
            notes: "Sample policy. Item must be unopened with receipt. Check with the retailer."
        ),
        RetailerPolicyTemplate(
            retailerName: "Kmart",
            windowDays: 30,
            notes: "Sample policy. Bring proof of purchase. Check with the retailer."
        ),
        RetailerPolicyTemplate(
            retailerName: "Officeworks",
            windowDays: 30,
            notes: "Sample policy. Technology items may need to be unopened. Check with the retailer."
        ),
        RetailerPolicyTemplate(
            retailerName: "Big W",
            windowDays: 30,
            notes: "Sample policy. Keep original packaging. Check with the retailer."
        ),
        RetailerPolicyTemplate(
            retailerName: "Myer",
            windowDays: 30,
            notes: "Sample policy. Items must be unworn with tags attached. Check with the retailer."
        ),
        RetailerPolicyTemplate(
            retailerName: "Other retailer",
            windowDays: 30,
            notes: "Sample default. Check the retailer's own return policy."
        ),
    ]
}

extension SampleReturnPolicies {
    /// The generic policy used when the retailer isn't in the sample list.
    static var fallback: RetailerPolicyTemplate {
        all.first(where: { $0.retailerName == "Other retailer" })!
    }

    /// Suggests a sample policy for a receipt's retailer, e.g. "JB HI-FI BROADWAY" → JB Hi-Fi.
    /// Falls back to "Other retailer" if nothing matches.
    static func suggestedPolicy(forRetailer retailerName: String) -> RetailerPolicyTemplate {
        let match = all.first(where: { template in
            retailerName.localizedCaseInsensitiveContains(template.retailerName)
        })
    
        return match ?? fallback
    }
}
