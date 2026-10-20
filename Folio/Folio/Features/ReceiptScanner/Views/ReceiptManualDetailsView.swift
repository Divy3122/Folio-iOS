//
//  ReceiptManualDetailsView.swift
//  Folio
//
//  Created by Divy Patel on 18/10/2026.
//

import SwiftUI

/// Manual receipt metadata, deliberately independent of Apple Intelligence.
/// Bindings point to the scanner's draft; the storage module can consume them later.
struct ReceiptManualDetailsView: View {
    @Binding var retailerName: String?
    @Binding var receiptDate: Date?

    @State private var choosingDate = false
    @State private var proposedDate = Date()

    var body: some View {
        Section("Receipt Details") {
            TextField(
                "Retailer / store name",
                text: Binding(
                    get: { retailerName ?? "" },
                    set: { retailerName = $0.isEmpty ? nil : $0 }
                )
            )
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .accessibilityLabel("Retailer or store name")

            if receiptDate != nil {
                DatePicker(
                    "Receipt date",
                    selection: Binding(
                        get: { receiptDate ?? proposedDate },
                        set: { receiptDate = $0 }
                    ),
                    in: ...Date(),
                    displayedComponents: .date
                )

                Button("Clear receipt date") {
                    receiptDate = nil
                    choosingDate = false
                }
                .font(.footnote)
            } else if choosingDate {
                DatePicker(
                    "Choose receipt date",
                    selection: $proposedDate,
                    in: ...Date(),
                    displayedComponents: .date
                )

                HStack {
                    Button("Use selected date") {
                        receiptDate = proposedDate
                        choosingDate = false
                    }
                    Spacer()
                    Button("Cancel") { choosingDate = false }
                }
            } else {
                Button {
                    proposedDate = Date()
                    choosingDate = true
                } label: {
                    Label("Select receipt date", systemImage: "calendar")
                }
            }

            Text("Enter the retailer and purchase date yourself. Neither is guessed from the scanned receipt.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
