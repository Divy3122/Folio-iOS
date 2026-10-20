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

    // Curated suggested prompts (strictly query & advice focus)
    static let suggestedPrompts: [String] = [
        "Do I have any warranties expiring soon?",
        "Can I return my most recent purchase?",
        "What electronics did I buy a year ago?",
        "How much have I spent on Groceries recently?"
    ]

    init(services: ReceiptLibraryServices) {
        self.services = services
        addInitialWelcomeMessage()
    }

    func loadAndPrepareContext() async {
        let filter = ReceiptFilter(searchText: "", profile: nil, sort: .dateDescending)
        allRecords = (try? await services.searchReceipts(filter)) ?? []
        
        // Prepare system prompt for Apple Intelligence
        if systemModel.availability == .available {
            let contextPrompt = buildReceiptsContextPrompt()
            let instructions = """
            You are Folio's intelligent, privacy-first receipt assistant.
            Answer questions about purchase history, return policy deadlines, warranty coverages, and total spending.
            Base your answers strictly on the user's saved receipt data provided below.
            Be concise, helpful, and clear.
            
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
            let (responseText, matches) = await generateResponse(for: trimmed)
            let assistantMessage = AgentMessage(
                sender: .assistant,
                text: responseText,
                referencedReceipts: matches
            )
            messages.append(assistantMessage)
            isAnalyzing = false
        }
    }

    // MARK: - Reasoning & Response Generation

    private func generateResponse(for query: String) async -> (String, [ReceiptRecord]) {
        let matchedRecords = findRelevantRecords(for: query)

        // Leverage Apple Intelligence on-device model if available
        if let session = modelSession, systemModel.availability == .available {
            do {
                let aiResponse = try await session.respond(to: query)
                return (aiResponse.content, matchedRecords)
            } catch {
                // Fall back to local reasoning engine if model call fails
            }
        }

        // Local Fallback Engine
        return fallbackLocalResponse(for: query, matchedRecords: matchedRecords)
    }

    private func buildReceiptsContextPrompt() -> String {
        guard !allRecords.isEmpty else { return "No receipts saved." }
        
        return allRecords.map { record in
            let r = record.receipt
            let date = r.purchasedAt.formatted(date: .numeric, time: .omitted)
            let items = r.items.map { "\($0.quantity)x \($0.name)" }.joined(separator: ", ")
            let category = record.metadata.category.isEmpty ? "Uncategorized" : record.metadata.category
            let status = record.statusSummaryText
            return "• ID: \(record.id.uuidString) | Retailer: \(r.retailer.name) | Date: \(date) | Total: \(r.currencyCode) \(r.total) | Category: \(category) | Items: [\(items)] | Policy Status: \(status)"
        }.joined(separator: "\n")
    }

    private func findRelevantRecords(for query: String) -> [ReceiptRecord] {
        let lower = query.lowercased()
        let now = Date.now
        let calendar = Calendar.current

        // Temporal filter (e.g., "a year ago", "3 months ago", "recently")
        if lower.contains("year ago") {
            let yearAgo = calendar.date(byAdding: .year, value: -1, to: now) ?? now
            return allRecords.filter { calendar.isDate($0.receipt.purchasedAt, equalTo: yearAgo, toGranularity: .month) }
        }

        // Return eligibility filter
        if lower.contains("return") || lower.contains("eligible") {
            return allRecords.filter { record in
                guard let days = record.receipt.returnPolicy?.windowDays else { return false }
                let deadline = calendar.date(byAdding: .day, value: days, to: record.receipt.purchasedAt) ?? .distantPast
                return deadline > now
            }
        }

        // Warranty filter
        if lower.contains("warranty") || lower.contains("warranties") {
            return allRecords.filter { record in
                record.metadata.policies.contains { $0.kind == .warranty }
            }
        }

        // Keyword & Retailer matching
        return allRecords.filter { record in
            let retailer = record.receipt.retailer.name.lowercased()
            let category = record.metadata.category.lowercased()
            let items = record.receipt.items.map { $0.name.lowercased() }
            return lower.contains(retailer) || lower.contains(category) || items.contains(where: { lower.contains($0) })
        }
    }

    private func fallbackLocalResponse(for query: String, matchedRecords: [ReceiptRecord]) -> (String, [ReceiptRecord]) {
        let lower = query.lowercased()

        if lower.contains("warranty") || lower.contains("warranties") {
            if matchedRecords.isEmpty {
                return ("No active warranties were found on your saved receipts.", [])
            }
            let names = matchedRecords.map { $0.receipt.retailer.name }.joined(separator: ", ")
            return ("You have active warranties registered for purchases from: **\(names)**.", matchedRecords)
        }

        if lower.contains("return") {
            if matchedRecords.isEmpty {
                return ("You don't currently have any purchases within an open return window.", [])
            }
            return ("Here are the items currently eligible for return:", matchedMatchedLimit(matchedRecords))
        }

        if lower.contains("spend") || lower.contains("total") || lower.contains("cost") {
            let totalDecimal = (matchedRecords.isEmpty ? allRecords : matchedRecords).reduce(Decimal.zero) { $0 + $1.receipt.total }
            let formattedTotal = totalDecimal.formatted(.currency(code: "AUD"))
            return ("The total calculated for those receipts is **\(formattedTotal)**.", matchedRecords)
        }

        if !matchedRecords.isEmpty {
            return ("Here is what I found in your library for your query:", matchedRecords)
        }

        return ("I searched your receipt library but couldn't find matching records. Try searching by retailer name, product type, or policy window.", [])
    }

    private func matchedMatchedLimit(_ records: [ReceiptRecord]) -> [ReceiptRecord] {
        Array(records.prefix(4))
    }

    private func addInitialWelcomeMessage() {
        messages.append(
            AgentMessage(
                sender: .assistant,
                text: "Hi! I'm your Folio AI assistant powered by Apple Intelligence. Ask me anything about your purchases, return eligibility, or warranties."
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
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(model.messages) { message in
                                ChatBubbleView(message: message)
                                    .id(message.id)
                            }

                            if model.isAnalyzing {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Apple Intelligence reasoning…")
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

                // Suggested Prompt Carousel
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AgenticSearchViewModel.suggestedPrompts, id: \.self) { prompt in
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

                // Input Bar
                HStack(spacing: 10) {
                    TextField("Ask about warranties, returns or spend…", text: $model.currentInput)
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
                                : Color.accentColor
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
            .task { await model.loadAndPrepareContext() }
        }
    }
}

// MARK: - Chat Bubble Component

private struct ChatBubbleView: View {
    let message: AgentMessage

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
                        isUser ? Color.accentColor : Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )

                if !message.referencedReceipts.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(message.referencedReceipts) { record in
                            NavigationLink(value: record) {
                                HStack {
                                    RetailerAvatar(name: record.receipt.retailer.name, size: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(record.receipt.retailer.name)
                                            .font(.caption.bold())
                                            .foregroundStyle(Color.primary)
                                        Text(record.receipt.total.formatted(.currency(code: record.receipt.currencyCode)))
                                            .font(.caption2)
                                            .foregroundStyle(Color.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }
                    .frame(maxWidth: 280)
                }
            }

            if !isUser { Spacer(minLength: 40) }
        }
    }
}
