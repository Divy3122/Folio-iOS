import SwiftUI
import VisionKit

struct ReceiptScannerView: View {
    @State private var viewModel = ReceiptScannerViewModel()
    @State private var showingCamera = false
    @State private var confirmingNewScan = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ReceiptCostReviewView(viewModel: viewModel)
                .navigationTitle("Receipt Review")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            if viewModel.hasReview { confirmingNewScan = true }
                            else { openCamera() }
                        } label: { Label("Scan Receipt", systemImage: "doc.viewfinder") }
                        .disabled(viewModel.isProcessing)
                    }
                }
                .confirmationDialog("Replace this review with a new scan?", isPresented: $confirmingNewScan, titleVisibility: .visible) {
                    Button("Scan a new receipt", role: .destructive, action: openCamera)
                } message: {
                    Text("A completed new scan replaces the current local draft and its images. Cancelling the camera keeps this review.")
                }
                .sheet(isPresented: $showingCamera) {
                    ReceiptDocumentCamera(
                        onScan: { pages in
                            showingCamera = false
                            viewModel.startProcessing(pages: pages)
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

    private func openCamera() {
        if VNDocumentCameraViewController.isSupported { showingCamera = true }
        else { viewModel.reportUnsupportedCamera() }
    }
}

#Preview { ReceiptScannerView() }
