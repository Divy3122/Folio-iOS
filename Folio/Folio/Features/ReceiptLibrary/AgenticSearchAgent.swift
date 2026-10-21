//
//  AgenticSearchAgent.swift
//  Folio
//
//  Created by Ziyan Nadeem on 21/10/2026.
//

import SwiftUI
import FoundationModels

// MARK: - Ephemeral Chat Models

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

    // Curated initial prompts
    static let suggestedPrompts: [String] = [
        "How can I cut down on my spending?",
        "Do I have any warranties expiring soon?",
        "Can I return my most recent purchase?",
        "What have I spent on Groceries lately?"
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
            You are Folio's friendly, conversational, and smart AI financial peer and receipt assistant.
            
            YOUR OBJECTIVES:
            1. Answer questions about purchase history, return policy deadlines, warranty coverages, and spending.
            2. Proactively offer personalized, practical tips on how the user can save money based on their actual expenses (e.g., pointing out high-frequency spending, unused warranties, or high category totals).
            3. Be warm, conversational, and empathetic—like a knowledgeable friend helping them stay organized and budget-smart.
            
            STRICT RULES:
            - NEVER display, output, or reference raw database IDs, UUIDs, or primary keys. Refer to purchases only by retailer name, items, or dates.
            - Keep your responses direct, clear, and action-oriented.
            
            Current Date: \(Date.now.formatted(date: .long, time: .omitted))
            
            Saved Receipts Context:
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
            let (responseText, matches, followUps) = await generateResponse(for: trimmed)
            let assistantMessage = AgentMessage(
                sender: .assistant,
                text: responseText,
                referencedReceipts: matches,
                followUpPrompts: followUps
            )
            messages.append(assistantMessage)
            isAnalyzing = false
        }
    }

    // MARK: - Reasoning & Response Generation

    private func generateResponse(for query: String) async -> (String, [ReceiptRecord], [String]) {
        if isInvalidQuery(query) {
            let invalidMsg = "Hey there! I can help you analyze your spending, check return deadlines, find warranties, or suggest ways to cut costs. What would you like to explore?"
            return (invalidMsg, [], Self.suggestedPrompts)
        }

        let matchedRecords = findPreciseRelevantRecords(for: query)
        let followUps = generateFollowUps(for: query, matches: matchedRecords)

        // Leverage Apple Intelligence on-device model if available
        if let session = modelSession, systemModel.availability == .available {
            do {
                let aiResponse = try await session.respond(to: query)
                let cleanedContent = sanitizeOutput(aiResponse.content)
                return (cleanedContent, matchedRecords, followUps)
            } catch {
                // Fallback to local intelligence engine if AI model call fails
            }
        }

        // Conversational Fallback Engine with Cost-Saving Logic
        let (responseText, records) = fallbackConversationalResponse(for: query, matchedRecords: matchedRecords)
        return (sanitizeOutput(responseText), records, followUps)
    }

    private func isInvalidQuery(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 2 { return true }
        let letters = trimmed.filter { $0.isLetter }
        return letters.isEmpty
    }

    private func buildReceiptsContextPrompt() -> String {
        guard !allRecords.isEmpty else { return "No receipts saved." }
        
        return allRecords.map { record in
            let r = record.receipt
            let date = r.purchasedAt.formatted(date: .numeric, time: .omitted)
            let items = r.items.map { "\($0.quantity)x \($0.name) (\(r.currencyCode) \($0.unitPrice))" }.joined(separator: ", ")
            let category = record.metadata.category.isEmpty ? "Uncategorized" : record.metadata.category
            let status = record.statusSummaryText
            return "• Retailer: \(r.retailer.name) | Date: \(date) | Total: \(r.currencyCode) \(r.total) | Category: \(category) | Items: [\(items)] | Status: \(status)"
        }.joined(separator: "\n")
    }

    // MARK: - Precise Link Matching Logic

    private func findPreciseRelevantRecords(for query: String) -> [ReceiptRecord] {
        let lower = query.lowercased()
        let now = Date.now
        let calendar = Calendar.current

        // 1. Warranty Queries: strictly return receipts that have active warranty coverage
        if lower.contains("warranty") || lower.contains("warranties") {
            return allRecords.filter { record in
                record.metadata.policies.contains { $0.kind == .warranty }
            }
        }

        // 2. Return Queries: strictly return receipts with active open return windows
        if lower.contains("return") || lower.contains("eligible") {
            return allRecords.filter { record in
                guard let days = record.receipt.returnPolicy?.windowDays else { return false }
                let deadline = calendar.date(byAdding: .day, value: days, to: record.receipt.purchasedAt) ?? .distantPast
                return deadline > now
            }
        }

        // 3. Exact Retailer or Product Name Matching (avoid loose category fuzzy hits)
        let matchedByEntity = allRecords.filter { record in
            let retailer = record.receipt.retailer.name.lowercased()
            let items = record.receipt.items.map { $0.name.lowercased() }
            
            let mentionsRetailer = lower.contains(retailer)
            let mentionsItem = items.contains(where: { itemName in
                !itemName.isEmpty && lower.contains(itemName)
            })
            
            return mentionsRetailer || mentionsItem
        }

        if !matchedByEntity.isEmpty {
            return Array(matchedByEntity.prefix(3))
        }

        // 4. Exact Category Match (only when explicitly requested)
        let matchedByCategory = allRecords.filter { record in
            let category = record.metadata.category.lowercased()
            return !category.isEmpty && lower.contains(category)
        }

        if !matchedByCategory.isEmpty {
            return Array(matchedByCategory.prefix(3))
        }

        return []
    }

    // MARK: - Conversational Fallback & Budget Analysis

    private func fallbackConversationalResponse(for query: String, matchedRecords: [ReceiptRecord]) -> (String, [ReceiptRecord]) {
        let lower = query.lowercased()

        // Cost Saving & Expense Analysis Prompt
        if lower.contains("save") || lower.contains("cut") || lower.contains("budget") || lower.contains("spending") || lower.contains("tip") {
            return generateSpendingAdvice()
        }

        if lower.contains("warranty") || lower.contains("warranties") {
            if matchedRecords.isEmpty {
                return ("I checked your library—it looks like you don't have any active warranties registered on your receipts right now. When you make new tech or appliance purchases, be sure to save the warranty policy so I can track it for you!", [])
            }
            let names = Set(matchedRecords.map { $0.receipt.retailer.name }).joined(separator: ", ")
            return ("You currently have active warranty protection on items from **\(names)**. Here are the specific receipts:", matchedRecords)
        }

        if lower.contains("return") {
            if matchedRecords.isEmpty {
                return ("Good news and bad news: you don't have any pending return deadlines, but none of your recent purchases are currently within an open return window.", [])
            }
            return ("You're still inside the return window for these recent purchases! Tap any receipt below to see the exact expiry date:", matchedRecords)
        }

        if !matchedRecords.isEmpty {
            return ("Here are the exact receipts matching your request:", matchedRecords)
        }

        return ("I searched through your receipts but couldn't find a direct match. Try asking about a specific retailer, product name, or ask me for tips on how to cut down your spending!", [])
    }

    private func generateSpendingAdvice() -> (String, [ReceiptRecord]) {
        guard !allRecords.isEmpty else {
            return ("Once you add a few receipts, I'll analyze your expenses and give you personalized tips on where you can save money!", [])
        }

        // Group spending by category
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

            let advice = """
            Here is a smart breakdown of your expenses:

            • **Total Tracked Spending:** \(overallAmount)
            • **Top Category:** **\(topCategory.key)** at **\(topAmount)**

            💡 **Cost-Saving Tip:**
            Your highest expenditure is in **\(topCategory.key)**. You might want to compare prices across different retailers or look out for store loyalty rewards on these items to trim your monthly costs!
            """

            return (advice, Array(highestSpendingRecords.prefix(3)))
        }

        return ("To keep your spending healthy, keep scanning receipts! I'll alert you whenever a category starts spiking.", [])
    }

    private func generateFollowUps(for query: String, matches: [ReceiptRecord]) -> [String] {
        let lower = query.lowercased()

        if lower.contains("save") || lower.contains("cut") || lower.contains("budget") {
            return [
                "Which category am I spending most on?",
                "Show eligible returns to get cash back",
                "How much did I spend this month?"
            ]
        } else if lower.contains("warranty") {
            return [
                "Can I return any recent items?",
                "How can I cut down on my spending?"
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
        let uuidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let regex = try? NSRegularExpression(pattern: uuidPattern, options: []) else { return text }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    private func addInitialWelcomeMessage() {
        messages.append(
            AgentMessage(
                sender: .assistant,
                text: "Hi! I'm your Folio financial assistant. Ask me anything about your purchases, return windows, or ask for personalized tips on how to save money on your expenses!",
                followUpPrompts: Self.suggestedPrompts
            )
        )
    }
}

// MARK: - Agentic Search Sheet View (Ephemeral)

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
                // Chat Message Stream
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
                                    Text("Thinking & analyzing expenses…")
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
                    .onChange(of: model.messages.count) {
                        if let lastID = model.messages.last?.id {
                            withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                        }
                    }
                }

                Divider()

                // Dynamic Follow-Up Prompt Suggestions
                if let lastMessage = model.messages.last, !lastMessage.followUpPrompts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(lastMessage.followUpPrompts, id: \.self) { prompt in
                                Button {
                                    model.sendPrompt(prompt)
                                } label: {
                                    Text(prompt)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color(.tertiarySystemFill), in: Capsule())
                                        .foregroundStyle(Color.primary)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }

                // Input Bar
                HStack(spacing: 10) {
                    TextField("Ask about spending, tips, warranties, or returns…", text: $model.currentInput)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .onSubmit { model.sendPrompt(model.currentInput) }

                    Button {
                        model.sendPrompt(model.currentInput)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(
                                model.currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.secondary
                                : Color.BrandTeal
                            )
                    }
                    .disabled(model.currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.systemGroupedBackground))
            }
            .navigationTitle("Receipt Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: ReceiptRecord.self) { record in
                ReceiptDetailView(record: record, services: services)
            }
            .task { await model.loadAndPrepareContext() }
        }
    }
}

// MARK: - Chat Bubble Component

private struct ChatBubbleView: View {
    let message: AgentMessage
    let services: ReceiptLibraryServices

    var isUser: Bool { message.sender == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
                Text(LocalizedStringKey(message.text))
                    .font(.subheadline)
                    .foregroundStyle(isUser ? Color.white : Color.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        isUser ? Color.BrandTeal : Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )

                // Rendered Precise Referenced Receipt Cards
                if !message.referencedReceipts.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(message.referencedReceipts) { record in
                            NavigationLink(value: record) {
                                HStack(spacing: 10) {
                                    RetailerAvatar(name: record.receipt.retailer.name, size: 32)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(record.receipt.retailer.name)
                                            .font(.caption.bold())
                                            .foregroundStyle(Color.primary)
                                        
                                        Text(record.receipt.purchasedAt, format: .dateTime.day().month().year())
                                            .font(.caption2)
                                            .foregroundStyle(Color.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Text(record.receipt.total.formatted(.currency(code: record.receipt.currencyCode)))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.primary)
                                    
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(Color.secondary)
                                }
                                .padding(10)
                                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    }
                    .frame(maxWidth: 290)
                }
            }

            if !isUser { Spacer(minLength: 40) }
        }
    }
}
