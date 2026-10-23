//
//  ReceiptDetailLoader.swift
//  Folio
//
//  Created by Brandon Hua on 22/10/2026.
//

import SwiftUI

/// Opens a receipt's detail screen from just its ID (e.g. when a reminder is tapped).
/// Fetches the full record first, because ReceiptDetailView needs it.
struct ReceiptDetailLoader: View {
    let receiptID: UUID
    let services: ReceiptLibraryServices

    @State private var record: ReceiptRecord?
    @State private var couldNotLoad = false

    var body: some View {
        Group {
            if let record {
                ReceiptDetailView(record: record, services: services)
            } else if couldNotLoad {
                ContentUnavailableView(
                    "Receipt not found",
                    systemImage: "doc.questionmark",
                    description: Text("This receipt may have been deleted.")
                )
            } else {
                ProgressView("Loading receipt…")
            }
        }
        .task {
            // Look up the full receipt; show "not found" if it's missing or fails to load
            do {
                record = try await services.repository.fetchRecord(id: receiptID)
                couldNotLoad = (record == nil)
            } catch {
                couldNotLoad = true
            }
        }
    }
}
