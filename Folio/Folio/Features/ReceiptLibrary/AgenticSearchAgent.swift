//
//  AgenticSearchAgent.swift
//  Folio
//
//  Created by Ziyan Nadeem on 21/10/2026.
//
import SwiftUI
import FoundationModels

// MARK: - Ephemeral Chat Models

struct DashboardInsight: Equatable {
    let periodName: String
    let totalSpending: Decimal
    let changePercentage: Decimal?
    let transactionCount: Int
    let averageTransaction: Decimal
    let topCategory: String
    let topCategoryAmount: Decimal
    let currencyCode: String
}

struct AgentMessage: Identifiable, Equatable {
    enum Sender {
        case user
        case assistant
    }

    let id = UUID()
    let sender: Sender
    let text: String
    let timestamp = Date.now
    var referencedReceipts: [ReceiptRecord] = []
    var followUpPrompts: [String] = []
    var dashboardInsight: DashboardInsight? = nil
}

// MARK: - Agentic Search View Model

@MainActor @Observable
final class AgenticSearchViewModel {
    var messages: [AgentMessage] = []
    var currentInput: String = ""
    var isAnalyzing: Bool = false

    private let services: ReceiptLibraryServices
    private var allRecords: [ReceiptRecord] = []
    
    // Apple Intelligence Session
    private let systemModel = SystemLanguageModel.default
    private var modelSession: LanguageModelSession?

    static let suggestedPrompts: [String] = [
        "Do I have any active warranties?",
        "Which items are within their return window?",
        "How am I doing this month vs last month?",
        "What is my personal vs business spend?"
    ]

    init(services: ReceiptLibraryServices) {
        self.services = services
        addInitialWelcomeMessage()
    }

    func loadAndPrepareContext() async {
        let filter = ReceiptFilter(searchText: "", profile: nil, sort: .dateDescending)
        allRecords = (try? await services.searchReceipts(filter)) ?? []
        
        if systemModel.availability == .available {
            let contextPrompt = buildReceiptsContextPrompt()
            let instructions = """
            You are Folio's sharp, direct AI financial assistant.
            
            YOUR GOALS:
            1. Answer questions about warranty coverage strictly using the explicit warranty policies logged under the 'WARRANTIES LOGGED' section in the context.
            2. Never mix up Return Windows with Warranties. They are completely separate.
            3. NEVER assume standard 12-month or 1-year coverage. If a receipt has no explicit warranty policy or warranty note logged, explicitly tell the user that no warranty policy was logged for that purchase.
            4. State retailer, item name, exact calculated warranty expiry date, and remaining days whenever discussing warranties.
            
            STRICT RULES:
            - Keep answers direct and concise (2-3 sentences max).
            - ABSOLUTELY NO EMOJIS anywhere in your output.
            - NEVER display raw database IDs, UUIDs, or internal keys.
            
            Current Date: \(Date.now.formatted(date: .long, time: .omitted))
            
            Saved Receipts & Policy Context:
            \(contextPrompt)
            """
            modelSession = LanguageModelSession(instructions: instructions)
        }
    }

    func sendPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        currentInput = ""
        let userMessage = AgentMessage(sender: .user, text: trimmed)
        messages.append(userMessage)
        isAnalyzing = true

        Task {
            let (responseText, matches, followUps, insight) = await generateResponse(for: trimmed)
            let assistantMessage = AgentMessage(
                sender: .assistant,
                text: responseText,
                referencedReceipts: matches,
                followUpPrompts: followUps,
                dashboardInsight: insight
            )
            messages.append(assistantMessage)
            isAnalyzing = false
        }
    }

    // MARK: - Reasoning & Response Generation

    private func generateResponse(for query: String) async -> (String, [ReceiptRecord], [String], DashboardInsight?) {
        if isInvalidQuery(query) {
            let invalidMsg = "How can I help? I can look up your exact logged warranty expiration dates, active return deadlines, or spending trends across your receipts."
            return (invalidMsg, [], Self.suggestedPrompts, nil)
        }

        let matchedRecords = findPreciseRelevantRecords(for: query)
        let followUps = generateFollowUps(for: query, matches: matchedRecords)
        let insight = detectAndBuildDashboardInsight(for: query)

        if let session = modelSession, systemModel.availability == .available {
            do {
                let aiResponse = try await session.respond(to: query)
                let cleanedContent = sanitizeOutput(aiResponse.content)
                if !cleanedContent.isEmpty {
                    return (cleanedContent, matchedRecords, followUps, insight)
                }
            } catch {
                // Fallback to deterministic parser if model session call fails
            }
        }

        let (responseText, records) = fallbackConversationalResponse(for: query, matchedRecords: matchedRecords)
        return (sanitizeOutput(responseText), records, followUps, insight)
    }

    private func isInvalidQuery(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 2 { return true }
        let letters = trimmed.filter { $0.isLetter }
        return letters.isEmpty
    }

    // MARK: - Context Engine (Strict Logged Warranty Calculations)

    private func buildReceiptsContextPrompt() -> String {
        guard !allRecords.isEmpty else { return "No receipts saved." }

        let calendar = Calendar.current
        let now = Date.now
        
        let startOfCurrentMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let startOfPreviousMonth = calendar.date(byAdding: .month, value: -1, to: startOfCurrentMonth) ?? now
        
        let currentMonthRecords = allRecords.filter { $0.receipt.purchasedAt >= startOfCurrentMonth }
        let previousMonthRecords = allRecords.filter { $0.receipt.purchasedAt >= startOfPreviousMonth && $0.receipt.purchasedAt < startOfCurrentMonth }
        
        let currentTotal = currentMonthRecords.reduce(Decimal.zero) { $0 + $1.receipt.total }
        let previousTotal = previousMonthRecords.reduce(Decimal.zero) { $0 + $1.receipt.total }
        
        var momChange: Decimal? = nil
        if previousTotal > 0 {
            momChange = ((currentTotal - previousTotal) / previousTotal) * 100
        }

        let personalTotal = allRecords.filter { $0.receipt.profile == .personal }.reduce(Decimal.zero) { $0 + $1.receipt.total }
        let businessTotal = allRecords.filter { $0.receipt.profile == .business }.reduce(Decimal.zero) { $0 + $1.receipt.total }

        let primaryCurrency = allRecords.first?.receipt.currencyCode ?? "AUD"
        let overallTotal = allRecords.reduce(Decimal.zero) { $0 + $1.receipt.total }

        let summaryHeader = """
        DASHBOARD METRICS:
        - Overall Lifetime Total: \(overallTotal.formatted(.currency(code: primaryCurrency))) across \(allRecords.count) receipts
        - Current Month Spending: \(currentTotal.formatted(.currency(code: primaryCurrency))) (\(currentMonthRecords.count) transactions)
        - Previous Month Spending: \(previousTotal.formatted(.currency(code: primaryCurrency)))
        - Profile Split -> Personal: \(personalTotal.formatted(.currency(code: primaryCurrency))) | Business: \(businessTotal.formatted(.currency(code: primaryCurrency)))
        """

        let receiptList = allRecords.prefix(20).map { record -> String in
            let r = record.receipt
            let purchaseDateStr = r.purchasedAt.formatted(date: .numeric, time: .omitted)
            let items = r.items.map { "\($0.quantity)x \($0.name)" }.joined(separator: ", ")
            let profile = r.profile.rawValue.capitalized
            
            // 1. Return Window Calculation
            var returnText = "No return policy logged"
            if let windowDays = r.returnPolicy?.windowDays {
                if let returnDeadline = calendar.date(byAdding: .day, value: windowDays, to: r.purchasedAt) {
                    let deadlineStr = returnDeadline.formatted(date: .numeric, time: .omitted)
                    let remaining = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: returnDeadline)).day ?? 0
                    returnText = remaining >= 0 ? "Eligible until \(deadlineStr) (\(remaining) days left)" : "Expired on \(deadlineStr)"
                }
            }

            // 2. Exact Logged Warranties (No assumptions)
            let warrantyPolicies = record.metadata.policies.filter { $0.kind == .warranty }
            var warrantyText = "No explicit warranty logged"
            if !warrantyPolicies.isEmpty {
                let formattedWarranties = warrantyPolicies.map { pol -> String in
                    if let expiryDate = calendar.date(byAdding: .day, value: pol.windowDays, to: r.purchasedAt) {
                        let daysRemaining = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: expiryDate)).day ?? 0
                        let expiryStr = expiryDate.formatted(date: .numeric, time: .omitted)
                        let status = daysRemaining >= 0 ? "Active until \(expiryStr) (\(daysRemaining) days left)" : "Expired on \(expiryStr)"
                        return "'\(pol.title)' [\(status)]"
                    }
                    return "'\(pol.title)' (\(pol.windowDays) days window)"
                }
                warrantyText = formattedWarranties.joined(separator: "; ")
            }

            let notes = record.metadata.notes.trimmingCharacters(in: .whitespacesAndNewlines)

            var entry = "• Retailer: \(r.retailer.name) | Purchased: \(purchaseDateStr) | Total: \(r.currencyCode) \(r.total) | Profile: \(profile) | Items: [\(items)]"
            entry += "\n  - RETURN WINDOW: \(returnText)"
            entry += "\n  - WARRANTIES LOGGED: \(warrantyText)"
            if !notes.isEmpty { entry += "\n  - NOTES: \(notes)" }
            return entry
        }.joined(separator: "\n")

        return "\(summaryHeader)\n\nSAVED RECEIPT DETAILS:\n\(receiptList)"
    }

    private func detectAndBuildDashboardInsight(for query: String) -> DashboardInsight? {
        let lower = query.lowercased()
        let keywords = ["dashboard", "overview", "month", "spending", "budget", "trend", "summary", "compare", "save"]
        
        guard keywords.contains(where: { lower.contains($0) }), !allRecords.isEmpty else { return nil }

        let calendar = Calendar.current
        let now = Date.now
        let startOfCurrentMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let startOfPreviousMonth = calendar.date(byAdding: .month, value: -1, to: startOfCurrentMonth) ?? now

        let currentRecords = allRecords.filter { $0.receipt.purchasedAt >= startOfCurrentMonth }
        let previousRecords = allRecords.filter { $0.receipt.purchasedAt >= startOfPreviousMonth && $0.receipt.purchasedAt < startOfCurrentMonth }

        let currentTotal = currentRecords.reduce(Decimal.zero) { $0 + $1.receipt.total }
        let previousTotal = previousRecords.reduce(Decimal.zero) { $0 + $1.receipt.total }

        var changePercent: Decimal? = nil
        if previousTotal > 0 {
            changePercent = ((currentTotal - previousTotal) / previousTotal) * 100
        }

        var categoryTotals: [String: Decimal] = [:]
        for record in currentRecords.isEmpty ? allRecords : currentRecords {
            let cat = record.metadata.category.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = cat.isEmpty ? "Uncategorized" : cat
            categoryTotals[key, default: 0] += record.receipt.total
        }

        let topCat = categoryTotals.sorted { $0.value > $1.value }.first
        let primaryCurrency = allRecords.first?.receipt.currencyCode ?? "AUD"
        let avgTransaction = currentRecords.isEmpty ? 0 : currentTotal / Decimal(currentRecords.count)

        return DashboardInsight(
            periodName: currentRecords.isEmpty ? "Overall" : "This Month",
            totalSpending: currentRecords.isEmpty ? allRecords.reduce(0) { $0 + $1.receipt.total } : currentTotal,
            changePercentage: changePercent,
            transactionCount: currentRecords.isEmpty ? allRecords.count : currentRecords.count,
            averageTransaction: avgTransaction,
            topCategory: topCat?.key ?? "General",
            topCategoryAmount: topCat?.value ?? 0,
            currencyCode: primaryCurrency
        )
    }

    // MARK: - Filter Logic (Strictly Explicit Warranties)

    private func findPreciseRelevantRecords(for query: String) -> [ReceiptRecord] {
        let lower = query.lowercased()

        if lower.contains("warranty") || lower.contains("warranties") || lower.contains("applecare") || lower.contains("protection") {
            return allRecords.filter { record in
                let hasExplicitWarranty = record.metadata.policies.contains { $0.kind == .warranty }
                let notesLower = record.metadata.notes.lowercased()
                let hasWarrantyNote = notesLower.contains("warranty") || notesLower.contains("guarantee") || notesLower.contains("applecare")
                
                let itemNames = record.receipt.items.map { $0.name.lowercased() }
                let hasItemWarranty = itemNames.contains(where: { name in
                    name.contains("warranty") || name.contains("applecare") || name.contains("care+") || name.contains("protection")
                })

                return hasExplicitWarranty || hasWarrantyNote || hasItemWarranty
            }
        }

        if lower.contains("return") || lower.contains("eligible") {
            let now = Date.now
            let calendar = Calendar.current
            return allRecords.filter { record in
                guard let days = record.receipt.returnPolicy?.windowDays else { return false }
                let deadline = calendar.date(byAdding: .day, value: days, to: record.receipt.purchasedAt) ?? .distantPast
                return deadline > now
            }
        }

        if lower.contains("business") {
            return Array(allRecords.filter { $0.receipt.profile == .business }.prefix(3))
        }

        if lower.contains("personal") {
            return Array(allRecords.filter { $0.receipt.profile == .personal }.prefix(3))
        }

        let matchedByEntity = allRecords.filter { record in
            let retailer = record.receipt.retailer.name.lowercased()
            let items = record.receipt.items.map { $0.name.lowercased() }
            return lower.contains(retailer) || items.contains(where: { !$0.isEmpty && lower.contains($0) })
        }

        if !matchedByEntity.isEmpty {
            return Array(matchedByEntity.prefix(3))
        }

        return []
    }

    // MARK: - Conversational Fallback

    private func fallbackConversationalResponse(for query: String, matchedRecords: [ReceiptRecord]) -> (String, [ReceiptRecord]) {
        let lower = query.lowercased()
        let calendar = Calendar.current
        let now = Date.now

        if lower.contains("warranty") || lower.contains("warranties") || lower.contains("protection") {
            if matchedRecords.isEmpty {
                return ("I checked your saved receipts and didn't find any explicit warranty policies, warranty notes, or extended protection logged.", [])
            }

            var warrantySummaries: [String] = []

            for rec in matchedRecords {
                let retailer = rec.receipt.retailer.name
                let itemName = rec.receipt.items.first?.name ?? "Item"
                let warranties = rec.metadata.policies.filter { $0.kind == .warranty }

                if !warranties.isEmpty {
                    for pol in warranties {
                        if let expiryDate = calendar.date(byAdding: .day, value: pol.windowDays, to: rec.receipt.purchasedAt) {
                            let daysRemaining = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: expiryDate)).day ?? 0
                            let expStr = expiryDate.formatted(date: .numeric, time: .omitted)
                            if daysRemaining >= 0 {
                                warrantySummaries.append("**\(itemName)** (\(retailer)): '\(pol.title)' active until **\(expStr)** (\(daysRemaining) days left)")
                            } else {
                                warrantySummaries.append("**\(itemName)** (\(retailer)): '\(pol.title)' expired on **\(expStr)**")
                            }
                        }
                    }
                } else if !rec.metadata.notes.isEmpty {
                    warrantySummaries.append("**\(itemName)** (\(retailer)): Note - \(rec.metadata.notes)")
                }
            }

            if warrantySummaries.isEmpty {
                return ("I found matching purchase receipts, but none of them have an explicit warranty policy or note logged.", matchedRecords)
            }

            let text = "Here are your logged warranties:\n\n" + warrantySummaries.joined(separator: "\n")
            return (text, matchedRecords)
        }

        if lower.contains("return") {
            if matchedRecords.isEmpty {
                return ("You don't have any active return deadlines right now.", [])
            }

            let returnLines = matchedRecords.prefix(3).compactMap { rec -> String? in
                guard let window = rec.receipt.returnPolicy?.windowDays,
                      let deadline = calendar.date(byAdding: .day, value: window, to: rec.receipt.purchasedAt) else { return nil }
                let daysLeft = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: deadline)).day ?? 0
                let item = rec.receipt.items.first?.name ?? rec.receipt.retailer.name
                return "**\(item)** (eligible until \(deadline.formatted(date: .numeric, time: .omitted)), \(daysLeft) days remaining)"
            }.joined(separator: "; ")

            return ("Active return deadlines: \(returnLines).", matchedRecords)
        }

        if lower.contains("business") || lower.contains("personal") {
            let personalTotal = allRecords.filter { $0.receipt.profile == .personal }.reduce(Decimal.zero) { $0 + $1.receipt.total }
            let businessTotal = allRecords.filter { $0.receipt.profile == .business }.reduce(Decimal.zero) { $0 + $1.receipt.total }
            let currency = allRecords.first?.receipt.currencyCode ?? "AUD"
            
            let text = "Your personal spending is currently \(personalTotal.formatted(.currency(code: currency))) and your business spending is \(businessTotal.formatted(.currency(code: currency)))."
            return (text, matchedRecords)
        }

        if lower.contains("save") || lower.contains("cut") || lower.contains("budget") || lower.contains("spending") || lower.contains("month") {
            return generateSpendingAdvice()
        }

        if !matchedRecords.isEmpty {
            return ("Here are the receipts matching your request:", matchedRecords)
        }

        return ("I searched through your saved receipts but couldn't find a direct match. Try asking about a specific store, item, or your monthly budget!", [])
    }

    private func generateSpendingAdvice() -> (String, [ReceiptRecord]) {
        guard !allRecords.isEmpty else {
            return ("Once you add a few receipts, I'll analyze your expenses and give you personalized tips on where you can save money!", [])
        }

        var categoryTotals: [String: Decimal] = [:]
        var totalSpent: Decimal = 0

        for record in allRecords {
            let cat = record.metadata.category.isEmpty ? "General" : record.metadata.category
            categoryTotals[cat, default: 0] += record.receipt.total
            totalSpent += record.receipt.total
        }

        let sortedCategories = categoryTotals.sorted { $0.value > $1.value }
        let primaryCurrency = allRecords.first?.receipt.currencyCode ?? "AUD"

        if let topCategory = sortedCategories.first {
            let topAmount = topCategory.value.formatted(.currency(code: primaryCurrency))
            let overallAmount = totalSpent.formatted(.currency(code: primaryCurrency))
            let highestSpendingRecords = allRecords.filter {
                ($0.metadata.category.isEmpty ? "General" : $0.metadata.category) == topCategory.key
            }

            let advice = "Your top expense category is **\(topCategory.key)** at **\(topAmount)** out of **\(overallAmount)** total spending. Comparing prices across retailers or utilizing loyalty rewards in this category is your best opportunity to cut down expenses."

            return (advice, Array(highestSpendingRecords.prefix(3)))
        }

        return ("Keep scanning your receipts! As your library grows, I'll identify trends and flag areas where you can trim your spending.", [])
    }

    private func generateFollowUps(for query: String, matches: [ReceiptRecord]) -> [String] {
        let lower = query.lowercased()

        if lower.contains("save") || lower.contains("cut") || lower.contains("budget") || lower.contains("month") {
            return [
                "What is my personal vs business spend?",
                "Which category am I spending most on?",
                "Show eligible returns to get cash back"
            ]
        } else if lower.contains("warranty") {
            return [
                "Can I return any recent items?",
                "How am I doing this month vs last month?"
            ]
        } else if !matches.isEmpty {
            return [
                "How can I save money on these?",
                "Check return policy windows"
            ]
        }

        return Self.suggestedPrompts
    }

    private func sanitizeOutput(_ text: String) -> String {
        var result = text

        let uuidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        if let regex = try? NSRegularExpression(pattern: uuidPattern, options: []) {
            let range = NSRange(location: 0, length: result.utf16.count)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        result = String(result.unicodeScalars.filter { scalar in
            if scalar.properties.isEmojiPresentation || scalar.properties.isEmoji {
                if scalar.value >= 0x30 && scalar.value <= 0x39 { return true }
                if scalar.value == 0x23 || scalar.value == 0x2A { return true }
                return false
            }
            return true
        })

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addInitialWelcomeMessage() {
        messages.append(
            AgentMessage(
                sender: .assistant,
                text: "Hi! I'm your Folio financial assistant. Ask me about your monthly spending trends, warranties, or tips to save money.",
                followUpPrompts: Self.suggestedPrompts
            )
        )
    }
}

// MARK: - Agentic Search Sheet View

struct AgenticSearchSheetView: View {
    let services: ReceiptLibraryServices
    @State private var model: AgenticSearchViewModel
    @Environment(\.dismiss) private var dismiss

    init(services: ReceiptLibraryServices) {
        self.services = services
        _model = State(initialValue: AgenticSearchViewModel(services: services))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(model.messages) { message in
                                ChatBubbleView(message: message, services: services)
                                    .id(message.id)
                            }

                            if model.isAnalyzing {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Thinking & analyzing expenses...")
                                        .font(.footnote)
                                        .foregroundStyle(Color.secondary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: model.messages) { _, _ in
                        if let lastID = model.messages.last?.id {
                            withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                        }
                    }
                }

                VStack(spacing: 12) {
                    if !model.messages.isEmpty, let lastMsg = model.messages.last, !lastMsg.followUpPrompts.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(lastMsg.followUpPrompts, id: \.self) { prompt in
                                    Button(prompt) {
                                        model.sendPrompt(prompt)
                                    }
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.BrandTeal.opacity(0.12), in: Capsule())
                                    .foregroundStyle(Color.BrandTeal)
                                }
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        TextField("Ask about spending, returns, or advice...", text: $model.currentInput)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                            .onSubmit {
                                model.sendPrompt(model.currentInput)
                            }

                        Button {
                            model.sendPrompt(model.currentInput)
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                                .foregroundStyle(model.currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.BrandTeal)
                        }
                        .disabled(model.currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(16)
                .background(.regularMaterial)
            }
            .navigationTitle("AI Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await model.loadAndPrepareContext()
            }
        }
    }
}

// MARK: - Chat Bubble & Dashboard Insight Components

struct ChatBubbleView: View {
    let message: AgentMessage
    let services: ReceiptLibraryServices

    var body: some View {
        VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: 10) {
            HStack {
                if message.sender == .user { Spacer() }

                Text(message.text)
                    .font(.body)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        message.sender == .user ? Color.BrandTeal : Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .foregroundStyle(message.sender == .user ? .white : .primary)

                if message.sender == .assistant { Spacer() }
            }

            if let insight = message.dashboardInsight {
                DashboardInsightCard(insight: insight)
                    .padding(.top, 2)
            }

            if !message.referencedReceipts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Referenced Receipts")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.secondary)

                    ForEach(message.referencedReceipts) { record in
                        NavigationLink(destination: ReceiptDetailView(record: record, services: services)) {
                            HStack {
                                Image(systemName: "receipt")
                                    .foregroundStyle(Color.BrandTeal)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.receipt.retailer.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.primary)
                                    Text(record.receipt.purchasedAt, format: .dateTime.day().month().year())
                                        .font(.caption)
                                        .foregroundStyle(Color.secondary)
                                }
                                Spacer()
                                Text(record.receipt.total.formatted(.currency(code: record.receipt.currencyCode)))
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Color.primary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(Color.secondary)
                            }
                            .padding(10)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

struct DashboardInsightCard: View {
    let insight: DashboardInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(insight.periodName + " Overview", systemImage: "chart.bar.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.BrandTeal)

                Spacer()

                if let change = insight.changePercentage {
                    let isUp = change > 0
                    let valStr = String(format: "%.1f%%", NSDecimalNumber(decimal: change).doubleValue)
                    Label("\(isUp ? "+" : "")\(valStr) vs last period", systemImage: isUp ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isUp ? Color.orange : Color.green)
                }
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spent")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(insight.totalSpending.formatted(.currency(code: insight.currencyCode)))
                        .font(.headline.weight(.bold))
                }

                Divider()

                VStack(alignment: .leading, spacing: 2) {
                    Text("Top Category")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(insight.topCategory)
                        .font(.headline.weight(.semibold))
                }

                Spacer()
            }
        }
        .padding(14)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
