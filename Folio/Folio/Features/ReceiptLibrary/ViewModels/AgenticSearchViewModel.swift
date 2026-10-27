//
//  AgenticSearchViewModel.swift
//  Folio
//
//  Created by Ziyan Nadeem on 27/10/2026.
//

import SwiftUI
import FoundationModels

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
