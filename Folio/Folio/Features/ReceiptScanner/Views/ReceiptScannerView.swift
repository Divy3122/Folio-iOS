import SwiftUI
import VisionKit
import PhotosUI

struct ReceiptScannerView: View {
    @State private var viewModel: ReceiptScannerViewModel

    init(dependencies: DependencyContainer? = nil) {
        _viewModel = State(initialValue: ReceiptScannerViewModel(receipts: dependencies?.receipts))
    }

    private enum EntryMode { case scan, manual, photos }

    @State private var showingCamera = false
    @State private var showingResults = false
    @State private var showingSave = false
    @State private var isEditing = false
    @State private var confirmingReplacement = false
    @State private var pendingMode: EntryMode = .scan
    @State private var pendingSharedBatch: URL?
    @State private var showingPhotoPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var isImportingPhotos = false
    @State private var didSaveReceipt = false

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
                            requestEntry(.scan)
                        } label: {
                            Label("Scan Receipt", systemImage: "camera.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .cornerRadius(14)

                        HStack{
                            Button {
                                requestEntry(.photos)
                            } label: {
                                Label("Import photo", systemImage: "photo.on.rectangle")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.bordered)
                            .cornerRadius(14)
                            .disabled(isImportingPhotos)

                            Button {
                                requestEntry(.manual)
                            } label: {
                                Label("Manual Entry", systemImage: "square.and.pencil")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.bordered)
                            .cornerRadius(14)
                        }


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
                resultsScreen
            }
            .confirmationDialog(
                "Replace the saved receipt draft?",
                isPresented: $confirmingReplacement,
                titleVisibility: .visible
            ) {
                Button(replaceButtonTitle, role: .destructive) {
                    beginEntry(afterDialog: true)
                }
            } message: {
                Text("The new receipt replaces your local draft. Cancelling keeps the saved receipt.")
            }
            .sheet(isPresented: $showingCamera) {
                ReceiptDocumentCamera(
                    onScan: { pages in
                        showingCamera = false
                        startReview(with: pages)
                    },
                    onCancel: { showingCamera = false },
                    onError: { error in
                        showingCamera = false
                        viewModel.reportError(error)
                    }
                )
            }
            // Photo picker lives on the NavigationStack (same level as the camera sheet),
            // NOT inside navigationDestination, so it can actually present.
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: $photoSelection,
                maxSelectionCount: 10,
                selectionBehavior: .ordered,
                matching: .images
            )
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                Task { await importPhotos(items) }
            }
            .overlay {
                if isImportingPhotos {
                    ProgressView("Loading photos…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .task {
                await viewModel.restoreDraft()
                checkSharedInbox()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { checkSharedInbox() }
                else { Task { await viewModel.saveDraft() } }
            }
            .confirmationDialog(
                "Receipt shared from another app",
                isPresented: Binding(
                    get: { pendingSharedBatch != nil },
                    set: { if !$0 { pendingSharedBatch = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Replace draft and review", role: .destructive) {
                    if let batch = pendingSharedBatch { consumeSharedBatch(batch) }
                }
                Button("Discard shared receipt", role: .destructive) {
                    if let batch = pendingSharedBatch { SharedReceiptInbox.remove(batch) }
                }
            } message: {
                Text("You have an unsaved receipt draft. Cancel to decide later.")
            }
            .onDisappear { Task { await viewModel.saveDraft() } }
        }
    }

    // MARK: - Results screen

    @ViewBuilder
    private var resultsScreen: some View {
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
        .sheet(isPresented: $showingSave, onDismiss: {
            if didSaveReceipt {
                didSaveReceipt = false
                showingResults = false          // back to the scan screen once the sheet is gone
            }
        }) {
            ReceiptSaveSheet(
                costs: viewModel.review.costs,
                pages: viewModel.originalPages,
                onSaved: {
                    didSaveReceipt = true
                    Task { await viewModel.clearDraft() }   // removes the draft from memory and disk
                }
            )
        }
    }

    // MARK: - Entry flow

    private var replaceButtonTitle: String {
        switch pendingMode {
        case .manual: "Start manual receipt"
        case .photos: "Import a new receipt"
        case .scan: "Scan a new receipt"
        }
    }
    
    private func checkSharedInbox() {
        guard !isImportingPhotos, pendingSharedBatch == nil,
              let batch = SharedReceiptInbox.pendingBatches().first else { return }
        if viewModel.hasReview { pendingSharedBatch = batch }
        else { consumeSharedBatch(batch) }
    }

    private func consumeSharedBatch(_ batch: URL) {
        let pages = SharedReceiptInbox.pages(in: batch)
        SharedReceiptInbox.remove(batch)
        pendingSharedBatch = nil
        guard !pages.isEmpty else {
            viewModel.reportError(ScannerError.imageConversionFailed)
            return
        }
        startReview(with: pages)   // same OCR + Apple Intelligence pipeline as the camera
    }

    private func requestEntry(_ mode: EntryMode) {
        pendingMode = mode
        if viewModel.hasReview { confirmingReplacement = true }
        else { beginEntry(afterDialog: false) }
    }

    /// `afterDialog` delays presentation slightly: SwiftUI silently drops a sheet/picker
    /// that is presented while the confirmation dialog is still dismissing.
    private func beginEntry(afterDialog: Bool) {
        switch pendingMode {
        case .manual:
            viewModel.beginManualReceipt()
            isEditing = true
            showingResults = true
        case .photos:
            Task { @MainActor in
                if afterDialog { try? await Task.sleep(for: .milliseconds(400)) }
                showingPhotoPicker = true
            }
        case .scan:
            guard VNDocumentCameraViewController.isSupported else {
                viewModel.reportUnsupportedCamera()
                return
            }
            Task { @MainActor in
                if afterDialog { try? await Task.sleep(for: .milliseconds(400)) }
                showingCamera = true
            }
        }
    }

    /// Shared by the camera and the photo import: run the same pipeline, then show results.
    private func startReview(with pages: [Data]) {
        isEditing = false
        viewModel.startProcessing(pages: pages)
        showingResults = true
    }

    // MARK: - Photo import

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        isImportingPhotos = true
        defer {
            isImportingPhotos = false
            photoSelection = []
        }

        var pages: [Data] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            // Resize/convert off the main thread so large photos don't freeze the UI.
            let jpeg = await Task.detached(priority: .userInitiated) {
                Self.normalizedJPEG(from: data)
            }.value
            if let jpeg { pages.append(jpeg) }
        }

        guard !pages.isEmpty else {
            viewModel.reportError(ScannerError.imageConversionFailed)
            return
        }
        startReview(with: pages)
    }

    /// Converts HEIC/PNG to JPEG, bakes in orientation, and caps size so OCR and memory stay sane.
    nonisolated private static func normalizedJPEG(from data: Data, maxDimension: CGFloat = 3000) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxDimension / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.95)
    }
}

#Preview { ReceiptScannerView() }
