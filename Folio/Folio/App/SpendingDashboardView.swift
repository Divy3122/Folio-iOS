import Observation
import SwiftUI
import Charts

private enum SpendingPeriod: String, CaseIterable, Identifiable {
    case week = "Week"
    case month = "Month"
    case year = "Year"

    var id: String { rawValue }
}

struct SpendingCategory: Identifiable {
    let name: String
    let amount: Decimal

    var id: String { name }

    var chartValue: Double {
        NSDecimalNumber(decimal: amount).doubleValue
    }
}

struct RetailerSpending: Identifiable {
    let name: String
    let amount: Decimal
    let transactionCount: Int

    var id: String { name }

    var chartValue: Double {
        NSDecimalNumber(decimal: amount).doubleValue
    }
}

struct DailySpending: Identifiable {
    let date: Date
    let amount: Decimal

    var id: Date { date }

    var chartValue: Double {
        NSDecimalNumber(decimal: amount).doubleValue
    }
}

@MainActor
@Observable
final class SpendingDashboardViewModel {
    private let fetchReceipts: FetchReceipts
    private let repository: (any ReceiptLibraryRepository)?

    private(set) var records: [ReceiptRecord] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    var selectedProfile: PurchaseProfile = .personal
    var selectedPeriod: String = "Month"
    var selectedCurrency: String = "AUD"

    private let calendar = Calendar.current
    private let now = Date()

    init(container: DependencyContainer) {
        self.fetchReceipts = container.fetchReceipts
        self.repository = container.receipts as? any ReceiptLibraryRepository
    }

    func load() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        do {
            if let repository {
                records = try await repository.search(ReceiptFilter())
            } else {
                let receipts = try await fetchReceipts()
                records = receipts.map { ReceiptRecord(receipt: $0) }
            }

            if !availableCurrencies.contains(selectedCurrency),
               let firstCurrency = availableCurrencies.first {
                selectedCurrency = firstCurrency
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    var availableCurrencies: [String] {
        Array(Set(profileRecords.map { $0.receipt.currencyCode })).sorted()
    }

    private var profileRecords: [ReceiptRecord] {
        records.filter { $0.receipt.profile == selectedProfile }
    }

    private var currentRange: (start: Date, end: Date) {
        let component: Calendar.Component

        switch selectedPeriod {
        case "Week":
            component = .weekOfYear
        case "Year":
            component = .year
        default:
            component = .month
        }

        let start = calendar.dateInterval(
            of: component,
            for: now
        )?.start ?? calendar.startOfDay(for: now)

        let end = calendar.date(
            byAdding: component,
            value: 1,
            to: start
        ) ?? now

        return (start, end)
    }

    private var currentRecords: [ReceiptRecord] {
        profileRecords.filter {
            $0.receipt.currencyCode == selectedCurrency &&
            $0.receipt.purchasedAt >= currentRange.start &&
            $0.receipt.purchasedAt < currentRange.end
        }
    }

    private var previousRecords: [ReceiptRecord] {
        let duration = currentRange.end.timeIntervalSince(currentRange.start)
        let previousStart = currentRange.start.addingTimeInterval(-duration)

        return profileRecords.filter {
            $0.receipt.currencyCode == selectedCurrency &&
            $0.receipt.purchasedAt >= previousStart &&
            $0.receipt.purchasedAt < currentRange.start
        }
    }

    var totalSpending: Decimal {
        currentRecords.reduce(Decimal.zero) { $0 + $1.receipt.total }
    }

    var previousTotal: Decimal {
        previousRecords.reduce(Decimal.zero) { $0 + $1.receipt.total }
    }

    var transactionCount: Int {
        currentRecords.count
    }

    var averageTransaction: Decimal {
        guard !currentRecords.isEmpty else { return 0 }
        return totalSpending / Decimal(currentRecords.count)
    }

    var spendingChange: Decimal? {
        guard previousTotal != 0 else { return nil }
        return ((totalSpending - previousTotal) / previousTotal) * 100
    }

    var retailerBreakdown: [RetailerSpending] {
        let grouped = Dictionary(grouping: currentRecords) {
            $0.receipt.retailer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return grouped.map { name, values in
            RetailerSpending(
                name: name.isEmpty ? "Unknown retailer" : name,
                amount: values.reduce(Decimal.zero) { $0 + $1.receipt.total },
                transactionCount: values.count
            )
        }
        .sorted { $0.amount > $1.amount }
    }

    var categoryBreakdown: [SpendingCategory] {
        var totals: [String: Decimal] = [:]

        for record in currentRecords {
            let categoryName = record.metadata.category.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = categoryName.isEmpty ? "Uncategorized" : categoryName
            totals[key, default: 0] += record.receipt.total
        }

        return totals.map { name, amount in
            SpendingCategory(name: name, amount: amount)
        }
        .sorted { $0.amount > $1.amount }
    }

    var dailyBreakdown: [DailySpending] {
        let grouped = Dictionary(grouping: currentRecords) {
            calendar.startOfDay(for: $0.receipt.purchasedAt)
        }

        return grouped.map { date, values in
            DailySpending(
                date: date,
                amount: values.reduce(Decimal.zero) { $0 + $1.receipt.total }
            )
        }
        .sorted { $0.date < $1.date }
    }

    func money(_ amount: Decimal) -> String {
        amount.formatted(.currency(code: selectedCurrency))
    }

    var currencySymbol: String {
        Locale(identifier: "en_AU")
            .localizedString(forCurrencyCode: selectedCurrency) ?? selectedCurrency
    }
}

struct SpendingDashboardView: View {
    @State private var model: SpendingDashboardViewModel
    @State private var showAgentSearch = false
    private let container: DependencyContainer

    init(container: DependencyContainer) {
        self.container = container
        _model = State(initialValue: SpendingDashboardViewModel(container: container))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                profilePicker
                periodPicker
                currencyPicker

                if model.isLoading {
                    ProgressView("Loading spending...")
                        .frame(maxWidth: .infinity)
                } else if let message = model.errorMessage {
                    ContentUnavailableView {
                        Label("Unable to load spending", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await model.load() } }
                    }
                } else {
                    summarySection
                    categorySection
                    retailerSection
                    trendSection
                }
            }
            .padding()
        }
        .navigationTitle("Spending")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAgentSearch = true
                } label: {
                    Label("AI Assistant", systemImage: "sparkles")
                        .font(.headline)
                        .foregroundStyle(Color.BrandTeal)
                }
            }
        }
        .sheet(isPresented: $showAgentSearch) {
            if let services = (try? ReceiptLibraryServices(container: container)) ?? ReceiptSavingContext.current?.services {
                AgenticSearchSheetView(services: services)
            }
        }
        .task { await model.load() }
        .onChange(of: model.selectedProfile) { refreshCurrencyIfNeeded() }
    }

    private var profilePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profile")
                .font(.headline)

            Picker("Profile", selection: $model.selectedProfile) {
                Text("Personal").tag(PurchaseProfile.personal)
                Text("Business").tag(PurchaseProfile.business)
            }
            .pickerStyle(.segmented)
        }
    }

    private var periodPicker: some View {
        Picker("Period", selection: $model.selectedPeriod) {
            Text("Week").tag("Week")
            Text("Month").tag("Month")
            Text("Year").tag("Year")
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var currencyPicker: some View {
        if !model.availableCurrencies.isEmpty {
            Picker("Currency", selection: $model.selectedCurrency) {
                ForEach(model.availableCurrencies, id: \.self) {
                    Text($0).tag($0)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Overview")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("Total spending")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(model.money(model.totalSpending))
                    .font(.system(size: 34, weight: .bold))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                if let change = model.spendingChange {
                    let percentage = String(
                        format: "%.1f",
                        NSDecimalNumber(decimal: change).doubleValue
                    )

                    Label(
                        "\(change >= 0 ? "+" : "")\(percentage)% vs previous period",
                        systemImage: change > 0
                            ? "arrow.up.right"
                            : change < 0
                                ? "arrow.down.right"
                                : "minus"
                    )
                    .font(.subheadline)
                    .foregroundStyle(change > 0 ? .orange : .secondary)
                } else {
                    Text("No previous spending to compare")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))

            HStack(spacing: 12) {
                summaryCard(
                    title: "Transactions",
                    value: "\(model.transactionCount)",
                    icon: "receipt"
                )

                summaryCard(
                    title: "Average",
                    value: model.money(model.averageTransaction),
                    icon: "chart.bar"
                )
            }
        }
    }

    private func summaryCard(
        title: String,
        value: String,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.headline)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spending by category")
                .font(.title3.bold())

            Text("Based on saved receipt categories.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.categoryBreakdown.isEmpty {
                emptyMessage("No category data for this period.")
            } else {
                Chart(model.categoryBreakdown) { category in
                    SectorMark(
                        angle: .value("Amount", max(0, category.chartValue)),
                        innerRadius: .ratio(0.6),
                        angularInset: 2
                    )
                    .foregroundStyle(
                        by: .value("Category", category.name)
                    )
                }
                .frame(height: 220)
                .accessibilityLabel("Spending by category")

                ForEach(model.categoryBreakdown) { category in
                    HStack {
                        Text(category.name)
                        Spacer()
                        Text(model.money(category.amount))
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private var retailerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top retailers")
                .font(.title3.bold())

            if model.retailerBreakdown.isEmpty {
                emptyMessage("No retailer spending for this period.")
            } else {
                Chart(Array(model.retailerBreakdown.prefix(5))) { retailer in
                    BarMark(
                        x: .value("Spending", retailer.chartValue),
                        y: .value("Retailer", retailer.name)
                    )
                    .foregroundStyle(.blue.gradient)
                    .annotation(position: .trailing) {
                        Text(model.money(retailer.amount))
                            .font(.caption2)
                    }
                }
                .frame(
                    height: CGFloat(
                        min(model.retailerBreakdown.count, 5) * 48
                    )
                )
                .chartXAxisLabel("Spending")
            }

            ForEach(Array(model.retailerBreakdown.prefix(5))) { retailer in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(retailer.name)
                            .fontWeight(.medium)

                        Text("\(retailer.transactionCount) transactions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(model.money(retailer.amount))
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spending trend")
                .font(.title3.bold())

            if model.dailyBreakdown.isEmpty {
                emptyMessage("No spending trend available.")
            } else {
                Chart(model.dailyBreakdown) { day in
                    BarMark(
                        x: .value("Date", day.date, unit: .day),
                        y: .value("Spending", day.chartValue)
                    )
                    .foregroundStyle(.teal.gradient)
                }
                .frame(height: 200)
                .chartYAxisLabel("Amount (\(model.selectedCurrency))")
            }
        }
    }

    private func emptyMessage(_ message: String) -> some View {
        ContentUnavailableView(
            message,
            systemImage: "chart.bar.xaxis"
        )
        .frame(minHeight: 100)
    }

    private func refreshCurrencyIfNeeded() {
        if !model.availableCurrencies.contains(model.selectedCurrency),
           let first = model.availableCurrencies.first {
            model.selectedCurrency = first
        }
    }
}

#Preview {
    if let container = try? DependencyContainer.live() {
        SpendingDashboardView(container: container)
    } else {
        ContentUnavailableView(
            "Preview Unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text("Could not initialise the data container.")
        )
    }
}
