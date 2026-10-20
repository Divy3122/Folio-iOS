import Foundation

struct Company: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var aliases: [String] = []
    var legalName: String? = nil
    var domain: String?
    var businessIdentifier: String?
    var location: String?
    var confirmed = false
    var evidence: [CompanyIdentityEvidence] = []
    /// Local asset explicitly associated with this stable identity, never a name lookup.
    var logoAsset: String?
    var policies: [CompanyPolicy] = []
}

struct CompanyIdentityEvidence: Codable, Equatable, Sendable {
    var line: Int
    var quote: String
    var pageNumber: Int?
    var confidence: Double?
    var x: Double?
    var y: Double?
    var width: Double?
    var height: Double?
}

struct CompanyPolicy: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case changeOfMind, statutoryInformation }
    var id = UUID()
    var url: URL
    var region: String
    var kind: Kind
    var checkedAt: Date
    var source: String
    var historicalReference: String?
    var confirmedOfficial: Bool
    func officialURL(for company: Company) -> URL? {
        guard confirmedOfficial, company.confirmed, !source.isEmpty,
              url.scheme == "https", url.user == nil, url.password == nil,
              let domain = company.domain?.lowercased(), !domain.isEmpty,
              let host = url.host?.lowercased(), host == domain || host.hasSuffix("." + domain) else { return nil }
        return url
    }
}

/// Explicit documented roles; a retailer association never implies coverage.
struct PurchaseCompanyAssociation: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case manufacturer, warrantyProvider, insuranceProvider }
    var companyID: UUID
    var role: Role
    var documentTitle: String?
    var localDocumentReference: String?
}

struct CompanyReview: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case unknown, suggested, matched, confirmed }
    var name = ""
    var company: Company?
    var status: Status = .unknown
    var message = "Unknown Retailer — you can enter or select one."
    var alternatives: [Company] = []
}

@MainActor protocol CompanyRepository {
    func fetchAll() async throws -> [Company]
    func save(_ company: Company) async throws
}

protocol ReceiptCompanyIdentifying: Sendable {
    func identify(text: String, pages: [ReceiptOCRPage]) async throws -> [Company]
}
