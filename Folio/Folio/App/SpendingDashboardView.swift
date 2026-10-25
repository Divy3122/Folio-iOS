import SwiftUI
import Charts
import Observation

// MARK: - Dashboard Models

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

struct MonthlySpending: Identifiable {
    let date: Date
    let amount: Decimal

    var id: Date { date }

    var chartValue: Double {
        NSDecimalNumber(decimal: amount).doubleValue
    }
}

enum SpendingChartPage: String, CaseIterable, Identifiable {
    case categories = "Categories"
    case retailers = "Retailers"
    case daily = "Daily Trend"
    case monthly = "Monthly Trend"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .categories: return "chart.pie"
        case .retailers: return "chart.bar.horizontal"
        case .daily: return "chart.bar"
        case .monthly: return "calendar"
        }
    }
}

// MARK: - Dashboard View Model

@MainActor
@Observable
final class SpendingDashboardViewModel {

    let container: DependencyContainer
    private(set) var services: ReceiptLibraryServices?

    private(set) var records: [ReceiptRecord] = []

    var isLoading = false
    var errorMessage: String?

    var selectedCategory = "All"
    var selectedPeriod = "Month"
    var selectedCurrency = "AUD"

    let periods = ["Week", "Month", "Year"]

    let supportedCurrencies = [
        "AUD", "USD", "EUR", "GBP", "NZD",
        "CAD", "SGD", "JPY", "INR", "CNY"
    ]

    private let audPerUnit: [String: Decimal] = [
        "AUD": 1.0,
        "USD": 1.52,
        "EUR": 1.76,
        "GBP": 2.02,
        "NZD": 0.88,
        "CAD": 1.10,
        "SGD": 1.17,
        "JPY": 0.010,
        "INR": 0.018,
        "CNY": 0.21
    ]

    private let calendar = Calendar.current
    private let now = Date()

    init(container: DependencyContainer) {
        self.container = container
    }

    func load() async {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            let libraryServices = try ReceiptLibraryServices(container: container)
            self.services = libraryServices

            records = try await libraryServices.searchReceipts(ReceiptFilter.all)

            if !availableCategories.contains(selectedCategory) {
                selectedCategory = "All"
            }

            if !supportedCurrencies.contains(selectedCurrency) {
                selectedCurrency = "AUD"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Available Filters

    var availableCurrencies: [String] {
        supportedCurrencies
    }

    var availableCategories: [String] {
        let categories = Set(
            records
                .map { categoryName(for: $0) }
                .filter {
                    !$0.isEmpty &&
                    $0.caseInsensitiveCompare("Other") != .orderedSame &&
                    $0 != "Uncategorised"
                }
        )

        return ["All"] + categories.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    func categoryName(for record: ReceiptRecord) -> String {
        let category = record.metadata.category
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return category.isEmpty ? "Uncategorised" : category
    }

    // MARK: Currency Conversion

    private func convert(
        _ amount: Decimal,
        from sourceCurrency: String
    ) -> Decimal? {
        guard
            let sourceRate = audPerUnit[sourceCurrency],
            let targetRate = audPerUnit[selectedCurrency],
            targetRate != .zero
        else {
            return nil
        }

        return amount * sourceRate / targetRate
    }

    private func convertedTotal(
        for record: ReceiptRecord
    ) -> Decimal? {
        convert(
            record.receipt.total,
            from: record.receipt.currencyCode
        )
    }

    private func total(for records: [ReceiptRecord]) -> Decimal {
        records.reduce(Decimal.zero) { result, record in
            result + (convertedTotal(for: record) ?? .zero)
        }
    }

    private var convertibleRecords: [ReceiptRecord] {
        records.filter {
            convertedTotal(for: $0) != nil
        }
    }

    var unsupportedCurrencies: [String] {
        Array(
            Set(
                records.compactMap { record in
                    audPerUnit[record.receipt.currencyCode] == nil
                        ? record.receipt.currencyCode
                        : nil
                }
            )
        )
        .sorted()
    }

    // MARK: Date Ranges

    private var currentRange: DateInterval {
        let component: Calendar.Component

        switch selectedPeriod {
        case "Week":
            component = .weekOfYear
        case "Year":
            component = .year
        default:
            component = .month
        }

        return calendar.dateInterval(
            of: component,
            for: now
        ) ?? DateInterval(
            start: calendar.startOfDay(for: now),
            end: now
        )
    }

    private var previousRange: DateInterval {
        let duration = currentRange.duration

        return DateInterval(
            start: currentRange.start.addingTimeInterval(-duration),
            end: currentRange.start
        )
    }

    // MARK: Receipt Filtering

    private var categoryFilteredRecords: [ReceiptRecord] {
        convertibleRecords.filter { record in
            selectedCategory == "All" ||
            categoryName(for: record) == selectedCategory
        }
    }

    var currentReceipts: [ReceiptRecord] {
        categoryFilteredRecords.filter { record in
            record.receipt.purchasedAt >= currentRange.start &&
            record.receipt.purchasedAt < currentRange.end
        }
    }

    private var previousReceipts: [ReceiptRecord] {
        categoryFilteredRecords.filter { record in
            record.receipt.purchasedAt >= previousRange.start &&
            record.receipt.purchasedAt < previousRange.end
        }
    }

    // MARK: Summary

    var totalSpending: Decimal {
        total(for: currentReceipts)
    }

    var previousTotal: Decimal {
        total(for: previousReceipts)
    }

    var transactionCount: Int {
        currentReceipts.count
    }

    var averageSpending: Decimal {
        guard !currentReceipts.isEmpty else {
            return .zero
        }

        return totalSpending / Decimal(currentReceipts.count)
    }

    var spendingChange: Decimal? {
        guard previousTotal > .zero else {
            return nil
        }

        return ((totalSpending - previousTotal) / previousTotal) * Decimal(100)
    }

    func money(_ amount: Decimal) -> String {
        amount.formatted(.currency(code: selectedCurrency))
    }

    // MARK: Category Breakdown

    var categoryBreakdown: [SpendingCategory] {
        var totals: [String: Decimal] = [:]

        for record in currentReceipts {
            let category = categoryName(for: record)
            let amount = convertedTotal(for: record) ?? .zero

            totals[category, default: .zero] += amount
        }

        return totals.map { name, amount in
            SpendingCategory(
                name: name,
                amount: amount
            )
        }
        .sorted { $0.amount > $1.amount }
    }

    // MARK: Retailer Breakdown

    var retailerBreakdown: [RetailerSpending] {
        let grouped = Dictionary(
            grouping: currentReceipts
        ) { record in
            record.receipt.retailer.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        }

        return grouped.map { name, values in
            RetailerSpending(
                name: name.isEmpty ? "Unknown retailer" : name,
                amount: total(for: values),
                transactionCount: values.count
            )
        }
        .sorted { $0.amount > $1.amount }
    }

    // MARK: Daily Trend

    var dailyBreakdown: [DailySpending] {
        let grouped = Dictionary(
            grouping: currentReceipts
        ) { record in
            calendar.startOfDay(
                for: record.receipt.purchasedAt
            )
        }

        return grouped.map { date, values in
            DailySpending(
                date: date,
                amount: total(for: values)
            )
        }
        .sorted { $0.date < $1.date }
    }

    // MARK: Monthly Trend

    var monthlyBreakdown: [MonthlySpending] {
        let startOfThisMonth = calendar.dateInterval(
            of: .month,
            for: now
        )?.start ?? now

        let monthStarts = (0..<6).compactMap { offset in
            calendar.date(
                byAdding: .month,
                value: -offset,
                to: startOfThisMonth
            )
        }.reversed()

        return monthStarts.map { monthStart in
            let nextMonth = calendar.date(
                byAdding: .month,
                value: 1,
                to: monthStart
            ) ?? monthStart

            let monthlyRecords = categoryFilteredRecords.filter {
                $0.receipt.purchasedAt >= monthStart &&
                $0.receipt.purchasedAt < nextMonth
            }

            return MonthlySpending(
                date: monthStart,
                amount: total(for: monthlyRecords)
            )
        }
    }
}

// MARK: - Spending Dashboard View

struct SpendingDashboardView: View {

    @State private var model: SpendingDashboardViewModel
    @State private var selectedChart: SpendingChartPage = .categories
    @State private var showingAgenticSearch = false

    init(container: DependencyContainer) {
        _model = State(
            initialValue: SpendingDashboardViewModel(
                container: container
            )
        )
    }

    // Dynamic Overview Card Background strictly switching between allowed tokens
    private var overviewCardBackground: Color {
        guard let change = model.spendingChange else {
            return Color.CardBackground
        }
        if change > 0 {
            return Color.ErrorRed.opacity(0.15)
        } else if change < 0 {
            return Color.SuccessGreen.opacity(0.15)
        } else {
            return Color.WarningAmber.opacity(0.15)
        }
    }

    // Status Subtext Color strictly using allowed tokens
    private var overviewStatusColor: Color {
        guard let change = model.spendingChange else {
            return .secondary
        }
        if change > 0 {
            return Color.ErrorRed
        } else if change < 0 {
            return Color.SuccessGreen
        } else {
            return Color.WarningAmber
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                categorySelector
                periodSelector
                currencySelector

                if model.isLoading {
                    ProgressView("Loading spending...")
                        .frame(maxWidth: .infinity)
                }

                if let error = model.errorMessage {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(Color.ErrorRed)
                }

                if !model.unsupportedCurrencies.isEmpty {
                    Text(
                        "Receipts in \(model.unsupportedCurrencies.joined(separator: ", ")) " +
                        "are excluded because no conversion rate is configured."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                summarySection
                chartsSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Spending")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAgenticSearch = true
                } label: {
                    Image(systemName: "sparkles")
                        .font(.title3.weight(.semibold))
                }
            }
        }
        .task {
            await model.load()
        }
        .sheet(isPresented: $showingAgenticSearch) {
            if let services = model.services {
                AgenticSearchSheetView(services: services)
            }
        }
    }

    // MARK: Category Selector

    private var categorySelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Categories")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.availableCategories, id: \.self) { category in
                        Button {
                            model.selectedCategory = category
                        } label: {
                            Text(category)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background {
                                    Capsule()
                                        .fill(
                                            model.selectedCategory == category
                                                ? Color.accentColor
                                                : Color.CardBackground
                                        )
                                }
                                .foregroundStyle(
                                    model.selectedCategory == category
                                        ? Color.white
                                        : Color.primary
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Period Selector

    private var periodSelector: some View {
        Picker("Period", selection: $model.selectedPeriod) {
            ForEach(model.periods, id: \.self) { period in
                Text(period).tag(period)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Currency Selector

    private var currencySelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Currency", systemImage: "dollarsign.circle")

                Spacer()

                Menu {
                    ForEach(model.availableCurrencies, id: \.self) { currency in
                        Button {
                            model.selectedCurrency = currency
                        } label: {
                            if currency == model.selectedCurrency {
                                Label(
                                    currency,
                                    systemImage: "checkmark"
                                )
                            } else {
                                Text(currency)
                            }
                        }
                    }
                } label: {
                    Label(
                        model.selectedCurrency,
                        systemImage: "chevron.down"
                    )
                    .fontWeight(.medium)
                }
            }
        }
    }

    // MARK: Summary

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Overview")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Total Spending")
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
                        "\(change >= 0 ? "+" : "")\(percentage)% compared with previous period",
                        systemImage: change >= 0
                            ? "arrow.up.right"
                            : "arrow.down.right"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(overviewStatusColor)
                } else {
                    Text("No previous-period spending to compare")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                overviewCardBackground,
                in: RoundedRectangle(cornerRadius: 18)
            )

            HStack(spacing: 12) {
                summaryCard(
                    title: "Transactions",
                    value: "\(model.transactionCount)",
                    symbol: "receipt"
                )

                summaryCard(
                    title: "Average Receipt",
                    value: model.money(model.averageSpending),
                    symbol: "chart.bar"
                )
            }
        }
    }

    private func summaryCard(
        title: String,
        value: String,
        symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, minHeight: 95, alignment: .leading)
        .padding()
        .background(
            Color.CardBackground,
            in: RoundedRectangle(cornerRadius: 16)
        )
    }

    // MARK: Swipeable Charts

    private var chartsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spending Analytics")
                    .font(.headline)

                Spacer()

                Text("Swipe to explore")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TabView(selection: $selectedChart) {
                categoryChart
                    .tag(SpendingChartPage.categories)

                retailerChart
                    .tag(SpendingChartPage.retailers)

                dailyChart
                    .tag(SpendingChartPage.daily)

                monthlyChart
                    .tag(SpendingChartPage.monthly)
            }
            .frame(height: 350)
            .tabViewStyle(.page(indexDisplayMode: .always))
        }
    }

    // MARK: Chart 1 - Category Breakdown

    private var categoryChart: some View {
        chartCard(
            title: "Spending by Category",
            subtitle: "How your spending is distributed"
        ) {
            if model.categoryBreakdown.isEmpty {
                emptyChartMessage
            } else {
                Chart(model.categoryBreakdown) { category in
                    SectorMark(
                        angle: .value("Spending", category.chartValue),
                        innerRadius: .ratio(0.55),
                        angularInset: 2
                    )
                    .foregroundStyle(
                        by: .value("Category", category.name)
                    )
                    .annotation(position: .overlay) {
                        if category.chartValue > 0 {
                            Text(category.name)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                    }
                }
                .chartLegend(position: .bottom, spacing: 8)
            }
        }
    }

    // MARK: Chart 2 - Retailer Breakdown

    private var retailerChart: some View {
        chartCard(
            title: "Spending by Retailer",
            subtitle: "Your top five retailers"
        ) {
            let retailers = Array(
                model.retailerBreakdown.prefix(5)
            )

            if retailers.isEmpty {
                emptyChartMessage
            } else {
                Chart(retailers) { retailer in
                    BarMark(
                        x: .value("Spending", retailer.chartValue),
                        y: .value("Retailer", retailer.name)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .annotation(position: .trailing) {
                        Text(model.money(retailer.amount))
                            .font(.caption2)
                    }
                }
                .chartXAxis {
                    AxisMarks(position: .bottom)
                }
            }
        }
    }

    // MARK: Chart 3 - Daily Trend

    private var dailyChart: some View {
        chartCard(
            title: "Daily Spending",
            subtitle: "Spending over the selected period"
        ) {
            if model.dailyBreakdown.isEmpty {
                emptyChartMessage
            } else {
                Chart(model.dailyBreakdown) { day in
                    BarMark(
                        x: .value("Date", day.date),
                        y: .value("Spending", day.chartValue)
                    )
                    .foregroundStyle(Color.teal.gradient)
                    .cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { AxisValue in
                        AxisValueLabel(
                            format: .dateTime.day().month(.abbreviated)
                        )
                    }
                }
            }
        }
    }

    // MARK: Chart 4 - Monthly Trend

    private var monthlyChart: some View {
        chartCard(
            title: "Monthly Spending",
            subtitle: "Compare the last six months"
        ) {
            if model.monthlyBreakdown.isEmpty {
                emptyChartMessage
            } else {
                Chart(model.monthlyBreakdown) { month in
                    BarMark(
                        x: .value("Month", month.date, unit: .month),
                        y: .value("Spending", month.chartValue)
                    )
                    .foregroundStyle(Color.purple.gradient)
                    .cornerRadius(5)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { AxisValue in
                        AxisValueLabel(
                            format: .dateTime.month(.abbreviated)
                        )
                    }
                }
            }
        }
    }

    // MARK: Chart Components

    private func chartCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color.CardBackground,
            in: RoundedRectangle(cornerRadius: 18)
        )
    }

    private var emptyChartMessage: some View {
        ContentUnavailableView(
            "No Spending Data",
            systemImage: "chart.bar",
            description: Text(
                "Receipts for this selection will appear here."
            )
        )
    }
}
