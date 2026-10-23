import SwiftUI
import VisionKit

struct ReceiptScannerView: View {
    @State private var viewModel: ReceiptScannerViewModel

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
                VStack(spacing: 28) {
                    Spacer()

                    // Hero Icon Header
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 96, height: 96)
                        
                        Image(systemName: "doc.viewfinder")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }

                    // Titles & Description
                    VStack(spacing: 10) {
                        Text("Scan your receipt")
                            .font(.title.weight(.bold))
                        
                        Text("Capture all pages to see each product's cost and the total paid.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }

                    // Primary Actions
                    VStack(spacing: 12) {
                        Button {
                            requestEntry(manual: false)
                        } label: {
                            Label("Scan Receipt", systemImage: "camera.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .cornerRadius(14)

                        Button {
                            requestEntry(manual: true)
                        } label: {
                            Text("Enter receipt manually")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                        .cornerRadius(14)

                        if viewModel.hasReview {
                            Button {
                                isEditing = false
                                showingResults = true
                            } label: {
                                Label("Continue saved receipt", systemImage: "arrow.right.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.top, 4)
                            }
                        }
                    }
                    .padding(.top, 8)

                    // Feedback Notifications
                    VStack(spacing: 12) {
                        if let error = viewModel.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.red)
                                .padding(12)
                                .frame(maxWidth: .infinity)
                                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        if let warning = viewModel.storageWarning {
                            Text(warning)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical)
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showingResults) {
                Group {
                    if viewModel.isProcessing {
                        VStack(spacing: 20) {
                            ProgressView(viewModel.processingMessage)
                                .controlSize(.large)

                            Text("Preparing the product breakdown and total cost from your receipt.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)

                            Button("Stop and review manually", role: .cancel) {
                                isEditing = true
                                viewModel.cancelProcessing()
                            }
                            .buttonStyle(.bordered)
                            .padding(.top, 8)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            Label("Save to library", systemImage: "tray.and.arrow.down.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .cornerRadius(14)
                        .disabled(ReceiptAmountParser.parse(viewModel.review.total) == nil)
                        .padding(16)
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
