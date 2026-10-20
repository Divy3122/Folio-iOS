import SwiftUI
import VisionKit

struct ReceiptScannerView: View {
    @State private var viewModel: ReceiptScannerViewModel
    @State private var showingSearch = false

    init(dependencies: DependencyContainer? = nil) {
        _viewModel = State(initialValue: ReceiptScannerViewModel(receipts: dependencies?.receipts))
    }
    @State private var showingCamera = false
    @State private var showingResults = false
    @State private var showingSave = false
    @State private var isEditing = false
    @State private var confirmingReplacement = false
    @State private var pendingManualEntry = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "doc.viewfinder")
                        .font(.largeTitle).foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Scan your receipt").font(.title.bold())
                    Text("Capture all pages to see each product's cost and the total paid.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button {
                        requestEntry(manual: false)
                    } label: {
                        Label("Scan Receipt", systemImage: "camera")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Enter receipt manually") { requestEntry(manual: true) }
                        .buttonStyle(.bordered)
                    if viewModel.hasReview {
                        Button("Continue saved receipt") {
                            isEditing = false
                            showingResults = true
                        }
                    }
                    if let error = viewModel.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                    if let warning = viewModel.storageWarning {
                        Text(warning).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
            .navigationTitle("Receipt Scanner")
            .toolbar { Button("Find purchases", systemImage: "magnifyingglass") { showingSearch = true } }
            .sheet(isPresented: $showingSearch) { CompanyPurchaseSearchView(model: viewModel) }
            .navigationDestination(isPresented: $showingResults) {
                Group {
                    if viewModel.isProcessing {
                        VStack(spacing: 20) {
                            ProgressView(viewModel.processingMessage)
                            Text("Preparing the product breakdown and total cost from your receipt.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Stop and review manually", role: .cancel) {
                                isEditing = true
                                viewModel.cancelProcessing()
                            }
                        }
                        .padding()
                    } else {
                        ReceiptCostReviewView(viewModel: viewModel, isEditing: isEditing)
                    }
                }
                .navigationTitle(isEditing ? "Edit Receipt" : "Receipt Results")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(isEditing ? "Done" : "Edit") { isEditing.toggle() }
                            .disabled(viewModel.isProcessing)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if !viewModel.isProcessing {
                        Button { showingSave = true } label: {
                            Label("Save to library", systemImage: "tray.and.arrow.down")
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding()
                        .background(.bar)
                    }
                }
                .sheet(isPresented: $showingSave) {
                    ReceiptSaveSheet(costs: viewModel.review.costs, pages: viewModel.originalPages)
                }
            }
            .confirmationDialog("Replace the saved receipt draft?", isPresented: $confirmingReplacement, titleVisibility: .visible) {
                Button(pendingManualEntry ? "Start manual receipt" : "Scan a new receipt", role: .destructive) {
                    beginEntry()
                }
            } message: {
                Text("The new receipt replaces your local draft. Cancelling the camera keeps the saved receipt.")
            }
            .sheet(isPresented: $showingCamera) {
                ReceiptDocumentCamera(
                    onScan: { pages in
                        showingCamera = false
                        isEditing = false
                        viewModel.startProcessing(pages: pages)
                        showingResults = true
                    },
                    onCancel: { showingCamera = false },
                    onError: { error in
                        showingCamera = false
                        viewModel.reportError(error)
                    }
                )
            }
            .task { await viewModel.restoreDraft() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { Task { await viewModel.saveDraft() } }
            }
            .onDisappear { Task { await viewModel.saveDraft() } }
        }
    }

    private func requestEntry(manual: Bool) {
        pendingManualEntry = manual
        if viewModel.hasReview { confirmingReplacement = true }
        else { beginEntry() }
    }

    private func beginEntry() {
        if pendingManualEntry {
            viewModel.beginManualReceipt()
            isEditing = true
            showingResults = true
        } else if VNDocumentCameraViewController.isSupported {
            showingCamera = true
        } else {
            viewModel.reportUnsupportedCamera()
        }
    }
}

#Preview { ReceiptScannerView() }
