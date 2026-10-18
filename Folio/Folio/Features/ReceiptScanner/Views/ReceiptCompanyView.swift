import SwiftUI
import UIKit

struct CompanyLogoView: View {
    let company: Company?
    static func asset(for company: Company?) -> String? {
        guard let company, company.confirmed, let asset = company.logoAsset,
              UIImage(named: asset) != nil else { return nil }
        return asset
    }
    var body: some View {
        Group {
            if let asset = Self.asset(for: company) {
                Image(asset).resizable().scaledToFit()
            } else {
                Image(systemName: "building.2.crop.circle").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }.frame(width: 40, height: 40).accessibilityHidden(true)
    }
}

struct ReceiptCompanyView: View {
    @Bindable var model: ReceiptScannerViewModel
    @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CompanyLogoView(company: model.companyReview.company)
                VStack(alignment: .leading) {
                    Text("Retailer").font(.caption).foregroundStyle(.secondary)
                    Text(model.companyReview.name.isEmpty ? "Unknown Retailer" : model.companyReview.name).font(.headline)
                }
                Spacer()
                if model.identifyingCompany { ProgressView().accessibilityLabel("Identifying retailer") }
            }
            Text(model.companyReview.message).font(.caption).foregroundStyle(.secondary)
            if editing {
                TextField("Retailer name", text: Binding(get: { model.companyReview.name }, set: model.editCompanyName))
                    .textContentType(.organizationName)
            }
            HStack {
                if model.companyReview.status != .confirmed, !model.companyReview.name.isEmpty {
                    Button("Confirm") { Task { await model.confirmCompany() } }.buttonStyle(.bordered).disabled(model.confirmingCompany)
                }
                Button(editing ? "Done editing" : "Edit retailer") { editing.toggle() }.buttonStyle(.borderless)
                Menu("Select retailer") {
                    ForEach(model.availableCompanies.filter(\.confirmed)) { company in
                        Button(company.name) { model.selectCompany(company) }
                    }
                    ForEach(model.companyReview.alternatives) { company in
                        Button("Suggested: " + company.name) { model.proposeCompany(company) }
                    }
                    Button("Enter new retailer") { model.editCompanyName(""); editing = true }
                }
            }
            if let company = model.companyReview.company, model.companyReview.status == .confirmed {
                ForEach(company.policies) { policy in
                    if let url = policy.officialURL(for: company) {
                        Link(policy.kind == .changeOfMind ? "Official change-of-mind policy" : "Official consumer-guarantee information", destination: url)
                        Text("\(policy.region) • Checked \(policy.checkedAt.formatted(date: .abbreviated, time: .omitted)) • May have changed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let message = model.companyMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.task { await model.loadCompanies() }
    }
}

struct CompanyPurchaseSearchView: View {
    @Bindable var model: ReceiptScannerViewModel
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List(model.historicalReceipts) { receipt in
                NavigationLink {
                    List {
                        Text(receipt.retailer.name).font(.headline)
                        Text(receipt.purchasedAt.formatted(date: .long, time: .omitted))
                        Text("\(receipt.currencyCode) \(ReceiptAmountParser.text(receipt.total))")
                        ForEach(receipt.items) { item in
                            VStack(alignment: .leading) {
                                Text(item.name)
                                ForEach(Array((item.companyAssociations ?? []).enumerated()), id: \.offset) { _, association in
                                    if let title = association.documentTitle { Text(title).font(.caption) }
                                }
                            }
                        }
                    }.navigationTitle("Saved purchase")
                } label: {
                    VStack(alignment: .leading) {
                        Text(receipt.retailer.name)
                        Text(receipt.items.map(\.name).joined(separator: ", ")).font(.caption)
                        Text(receipt.purchasedAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay { if model.historicalReceipts.isEmpty { ContentUnavailableView.search(text: query) } }
            .searchable(text: $query, prompt: "Retailer, manufacturer, product or document")
            .navigationTitle("Saved purchases")
            .task(id: query) { await model.searchPurchases(query) }
        }
    }
}
