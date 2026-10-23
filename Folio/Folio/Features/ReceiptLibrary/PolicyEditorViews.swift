//
//  PolicyEditorViews.swift
//  Folio
//
//  Created by Ziyan Nadeem on 21/10/2026.
//

import SwiftUI

struct PolicyEditor: View {
    @Binding var draft: PolicyDraft
    var showsApplies = false
    var purchaseDate: Date? = nil
    var hasExistingReminder = false
    let onRemove: () -> Void

    @State private var backup: PolicyDraft?
    @State private var showingDuplicateReminderAlert = false

    var body: some View {
        Group {
            if draft.isEditing {
                editor
            } else {
                summary
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: draft.isEditing)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(draft.kind == .returns ? "Policy Details" : "Warranty Details")
                .font(.headline)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                TextField(
                    draft.kind == .returns ? "Policy Name" : "Warranty Name",
                    text: $draft.title
                )
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()
                    .padding(.leading, 16)

                if draft.kind == .returns {
                    HStack {
                        Text("Return Window")
                        Spacer()
                        HStack(spacing: 4) {
                            TextField("Days", text: $draft.daysText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 54)
                            Text("days")
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                } else {
                    HStack {
                        Text("Warranty Duration")
                        Spacer()
                        HStack(spacing: 6) {
                            if draft.warrantyUnit != .lifetime {
                                TextField("Length", value: $draft.warrantyValue, format: .number)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 46)
                            }

                            Picker("Unit", selection: $draft.warrantyUnit) {
                                ForEach(PolicyDraft.WarrantyUnit.allCases) { unit in
                                    Text(unit.rawValue).tag(unit)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .tint(Color.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text("Notes")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 0) {
                    TextField("Optional conditions or exceptions", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...4)
                        .padding(16)
                }
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text("Add any conditions that help explain this policy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            if !draft.isValid {
                Label(
                    draft.kind == .returns
                        ? "Enter a policy name and return window (1–3,650 days)."
                        : "Enter a warranty name and valid duration.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 4)
            }

            Divider()
                .padding(.vertical, 2)

            HStack(spacing: 12) {
                Button(role: .destructive, action: onRemove) {
                    Text("Remove")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)

                if draft.isConfirmed {
                    Button {
                        if let backup { draft = backup }
                        draft.isEditing = false
                    } label: {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }

                Button {
                    draft.isConfirmed = true
                    draft.isEditing = false
                } label: {
                    Text("Save")
                        .bold()
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(!draft.isValid)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 10, x: 0, y: 4)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.title.isEmpty ? draft.kind.label : draft.title)
                        .font(.headline)

                    Text(draft.durationText)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)

                    if !draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(draft.notes)
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                            .padding(.top, 4)
                    }
                }

                Spacer(minLength: 8)

                Button("Edit") {
                    backup = draft
                    draft.isEditing = true
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }

            if showsApplies {
                Divider()
                Toggle("Apply to this receipt", isOn: $draft.applies)
                    .font(.subheadline)

                let baseDate = purchaseDate ?? Date()
                if draft.applies, let deadline = draft.deadline(from: baseDate) {
                    reminderView(
                        for: deadline,
                        policyKind: draft.kind == .returns ? "return policy" : "warranty",
                        hasExistingReminder: hasExistingReminder
                    )
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 10, x: 0, y: 4)
    }

    @ViewBuilder
    private func reminderView(
        for deadline: Date,
        policyKind: String? = nil,
        hasExistingReminder: Bool = false
    ) -> some View {
        let isPast = deadline <= Date.now
        let dateColor: Color = isPast ? Color.red : Color.primary
        let kindText = policyKind ?? (draft.kind == .returns ? "return policy" : "warranty")

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Expiry Date")
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                Spacer()
                Text(deadline, format: .dateTime.day().month().year())
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(dateColor)
            }

            if !isPast {
                Toggle("Create reminder", isOn: $draft.setReminder)
                    .font(.subheadline)
                    .onChange(of: draft.setReminder) { _, enabled in
                        if enabled {
                            if hasExistingReminder {
                                showingDuplicateReminderAlert = true
                            } else {
                                updateDefaultReminderDate(for: deadline)
                            }
                        }
                    }

                if draft.setReminder {
                    DatePicker(
                        "Remind me",
                        selection: $draft.reminderDate,
                        in: Date.now...deadline
                    )
                    .font(.subheadline)
                }
            } else {
                Text("Policy window has expired; reminder cannot be scheduled.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.top, 4)
        .alert(
            "Existing Reminder Found",
            isPresented: $showingDuplicateReminderAlert
        ) {
            Button("Add Another Reminder") {
                updateDefaultReminderDate(for: deadline)
            }
            Button("Cancel", role: .cancel) {
                draft.setReminder = false
            }
        } message: {
            Text("A reminder is already scheduled for this receipt's \(kindText). Do you want to add another? To remove existing reminders, visit the Reminders tab.")
        }
    }

    private func updateDefaultReminderDate(for deadline: Date) {
        let calendar = Calendar.current
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: deadline) ?? deadline
        let nineAM = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dayBefore) ?? dayBefore
        draft.reminderDate = nineAM > Date.now ? nineAM : Date.now.addingTimeInterval(300)
    }
}

struct PolicySections: View {
    @Binding var drafts: [PolicyDraft]
    var showsApplies = false
    var purchaseDate: Date? = nil
    var hasExistingReminder = false

    var body: some View {
        ForEach(SavedPolicy.Kind.allCases, id: \.self) { kind in
            Section {
                ForEach(indices(for: kind), id: \.self) { index in
                    PolicyRow(
                        draft: $drafts[index],
                        showsApplies: showsApplies,
                        purchaseDate: purchaseDate,
                        hasExistingReminder: hasExistingReminder,
                        onRemove: { removeDraft(at: index) }
                    )
                }

                Button {
                    drafts.append(.new(kind, applies: showsApplies))
                } label: {
                    Label(
                        kind == .returns ? "Add return policy" : "Add warranty",
                        systemImage: "plus.circle"
                    )
                }
            } header: {
                Text(kind == .returns ? "Return policies" : "Warranties")
            } footer: {
                Text(footer(for: kind))
            }
        }
    }

    private func indices(for kind: SavedPolicy.Kind) -> [Int] {
        drafts.indices.filter { drafts[$0].kind == kind }
    }

    private func removeDraft(at index: Int) {
        guard drafts.indices.contains(index) else { return }
        drafts.remove(at: index)
    }

    private func footer(for kind: SavedPolicy.Kind) -> String {
        switch (kind, showsApplies) {
        case (.returns, true):
            return "Turn on Apply to this receipt for each return policy that covers it."
        case (.warranty, true):
            return "Only warranties with Apply to this receipt turned on are saved with it."
        case (.returns, false):
            return "Set the return window in days. Add separate policies for change of mind, faulty items or other conditions."
        case (.warranty, false):
            return "Enter durations in days, months or years. They are stored as days."
        }
    }
}

// MARK: - Extracted Row Subview

private struct PolicyRow: View {
    @Binding var draft: PolicyDraft
    let showsApplies: Bool
    let purchaseDate: Date?
    let hasExistingReminder: Bool
    let onRemove: () -> Void

    var body: some View {
        PolicyEditor(
            draft: $draft,
            showsApplies: showsApplies,
            purchaseDate: purchaseDate,
            hasExistingReminder: hasExistingReminder,
            onRemove: onRemove
        )
    }
}

struct PolicyLiabilityNotice: View {
    var body: some View {
        Label {
            Text("You are responsible for entering accurate return and warranty policies. Folio can't verify them, and they are not legal advice or a statement of your consumer rights. Check the retailer's own terms.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
        }
        .font(.footnote)
    }
}

struct RetailerEditForm: View {
    @Binding var name: String
    @Binding var policies: [PolicyDraft]
    var purchaseDate: Date? = nil
    var hasExistingReminder = false

    var body: some View {
        Section("Retailer") {
            TextField("Retailer name", text: $name).textInputAutocapitalization(.words)
        }
        Section { PolicyLiabilityNotice() }
        PolicySections(drafts: $policies, purchaseDate: purchaseDate, hasExistingReminder: hasExistingReminder)
    }
}
