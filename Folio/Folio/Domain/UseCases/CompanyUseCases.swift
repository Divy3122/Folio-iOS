import Foundation

enum CompanyMatching {
    static func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }.lowercased()
    }
    static func matches(_ proposed: Company, records: [Company]) -> [Company] {
        records.filter { record in
            guard record.confirmed else { return false }
            let sameRegistration = proposed.businessIdentifier.map { !key($0).isEmpty && key($0) == record.businessIdentifier.map(key) } == true
            if !sameRegistration, let a = proposed.domain, let b = record.domain, a.lowercased() != b.lowercased() { return false }
            if let a = proposed.businessIdentifier, let b = record.businessIdentifier, key(a) != key(b) { return false }
            let strong = proposed.domain.map { $0.lowercased() == record.domain?.lowercased() } == true ||
                proposed.businessIdentifier.map { key($0) == record.businessIdentifier.map(key) } == true
            return strong || ([record.name] + record.aliases + [record.legalName].compactMap { $0 }).contains { !key($0).isEmpty && key($0) == key(proposed.name) }
        }
    }
    static func review(_ proposals: [Company], records: [Company]) -> CompanyReview {
        let unique = proposals.reduce(into: [Company]()) { result, candidate in
            if let index = result.firstIndex(where: {
                let conflict = ($0.businessIdentifier != nil && candidate.businessIdentifier != nil && key($0.businessIdentifier!) != key(candidate.businessIdentifier!))
                let names = Set(([$0.name] + $0.aliases + [$0.legalName].compactMap { $0 }).map(key))
                let candidateNames = Set(([candidate.name] + candidate.aliases + [candidate.legalName].compactMap { $0 }).map(key))
                let registration = $0.businessIdentifier.map { !key($0).isEmpty && key($0) == candidate.businessIdentifier.map(key) } == true
                return !conflict && (registration || !names.isDisjoint(with: candidateNames)) && (registration || $0.domain == nil || candidate.domain == nil || $0.domain == candidate.domain)
            }) {
                // Prefer an explicitly linked trading name over a duplicate legal-name proposal.
                if candidate.legalName.map(key) == key(result[index].name), key(candidate.name) != key(result[index].name) {
                    result[index].aliases.append(result[index].name)
                    result[index].name = candidate.name
                }
                result[index].aliases = Array(Set(result[index].aliases + candidate.aliases)).sorted()
                result[index].businessIdentifier = result[index].businessIdentifier ?? candidate.businessIdentifier
                result[index].legalName = result[index].legalName ?? candidate.legalName
                result[index].evidence += candidate.evidence
            } else { result.append(candidate) }
        }
        guard unique.count == 1, let proposal = unique.first else {
            return CompanyReview(status: unique.isEmpty ? .unknown : .suggested, message: unique.isEmpty ? "Unknown Retailer — enter or select one." : "Multiple receipt issuers are possible. Select the retailer.", alternatives: unique)
        }
        let found = matches(proposal, records: records)
        if found.count == 1, let company = found.first {
            return CompanyReview(name: company.name, company: company, status: .matched, message: "Matches a previously confirmed retailer. Confirm for this receipt.")
        }
        return CompanyReview(name: proposal.name, company: proposal, status: .suggested,
                             message: "Suggested from receipt evidence — confirmation required.")
    }
    /// Only exact, previously confirmed identifiers in header evidence enable offline reuse.
    static func offline(text: String, records: [Company]) -> [Company] {
        let header = text.components(separatedBy: .newlines).prefix(10).joined(separator: "\n").lowercased()
        return records.filter { record in
            record.confirmed && [record.domain, record.businessIdentifier].compactMap { $0 }.contains { identifier in
                guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                let escaped = NSRegularExpression.escapedPattern(for: identifier.lowercased())
                return header.range(of: "(?<![a-z0-9])" + escaped + "(?![a-z0-9])", options: .regularExpression) != nil
            }
        }
    }
}

@MainActor struct ConfirmCompany {
    let repository: any CompanyRepository
    func callAsFunction(_ proposed: Company) async throws -> Company {
        var company = proposed
        company.name = company.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !company.name.isEmpty else { throw FolioError.invalidReceipt }
        let records = try await repository.fetchAll()
        let matches = CompanyMatching.matches(company, records: records)
        if matches.count == 1, var existing = matches.first {
            if !([existing.name] + existing.aliases).contains(company.name) { existing.aliases.append(company.name) }
            existing.aliases = Array(Set(existing.aliases + company.aliases)).sorted()
            existing.legalName = existing.legalName ?? company.legalName
            existing.businessIdentifier = existing.businessIdentifier ?? company.businessIdentifier
            try await repository.save(existing)
            return existing
        }
        guard matches.count <= 1 else { throw FolioError.invalidReceipt }
        company.confirmed = true
        try await repository.save(company)
        return company
    }
}

/// Permanent saving remains with SaveReceipt; this boundary preserves dates, items and totals.
struct AssociateReceiptCompany {
    func callAsFunction(_ receipt: PurchaseReceipt, company: Company) throws -> PurchaseReceipt {
        guard company.confirmed else { throw FolioError.invalidReceipt }
        var linked = receipt
        linked.retailer = Retailer(name: company.name, companyID: company.id)
        return linked
    }
}

@MainActor struct SearchCompanyPurchases {
    let receipts: any ReceiptRepository
    let companies: any CompanyRepository
    func callAsFunction(_ query: String) async throws -> [PurchaseReceipt] {
        let all = try await receipts.fetchAll()
        let records = try await companies.fetchAll()
        let needle = CompanyMatching.key(query)
        guard !needle.isEmpty else { return all.sorted { $0.purchasedAt > $1.purchasedAt } }
        return all.filter { receipt in
            let companyIDs = Set(([receipt.retailer.companyID].compactMap { $0 }) + receipt.items.flatMap { ($0.companyAssociations ?? []).map(\.companyID) })
            let names = records.filter { companyIDs.contains($0.id) }.flatMap { [$0.name] + $0.aliases }
            let documents = receipt.items.flatMap { ($0.companyAssociations ?? []).compactMap(\.documentTitle) }
            return ([receipt.retailer.name] + receipt.items.map(\.name) + names + documents)
                .contains { CompanyMatching.key($0).contains(needle) }
        }.sorted { $0.purchasedAt > $1.purchasedAt }
    }
}
