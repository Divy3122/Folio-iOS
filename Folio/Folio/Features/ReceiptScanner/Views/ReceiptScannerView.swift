//
//  ReceiptScannerView.swift
//  Folio
//
//  Created by Divy Patel on 16/10/2026.
//


import SwiftUI
import VisionKit

struct ReceiptScannerView: View {
    @State private var viewModel = ReceiptScannerViewModel()
    @State private var showingCamera = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Button {
                        if VNDocumentCameraViewController.isSupported {
                            showingCamera = true
                        } else {
                            viewModel.reportUnsupportedCamera()
                        }
                    } label: {
                        Label("Scan Receipt", systemImage: "doc.viewfinder")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isProcessing)

                    if viewModel.isProcessing {
                        ProgressView("Recognising receipt text...")
                    }

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .accessibilityAddTraits(.updatesFrequently)
                    }

                    if !viewModel.extractedText.isEmpty {
                        Text("\(viewModel.pageCount) page(s) scanned")
                            .font(.headline)

                        Text("Recognised text — not yet verified")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $viewModel.extractedText)
                            .frame(minHeight: 300)
                            .padding(8)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding()
            }
            .navigationTitle("Receipt Scanner")
            .sheet(isPresented: $showingCamera) {
                ReceiptDocumentCamera(
                    onScan: { pages in
                        showingCamera = false

                        Task {
                            await viewModel.process(pages: pages)
                        }
                    },
                    onCancel: {
                        showingCamera = false
                    },
                    onError: { error in
                        showingCamera = false
                        viewModel.reportError(error)
                    }
                )
            }
        }
    }
}

#Preview {
    ReceiptScannerView()
}
