//
//  ShareViewController.swift
//  Folio
//
//  Created by Ziyan Nadeem on 27/10/2026.
//

import UIKit
import SwiftUI
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()

        let host = UIHostingController(rootView: ShareStatusView(model: model) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)

        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        Task { await model.importImages(from: providers) }
    }
}

@MainActor @Observable
final class ShareModel {
    enum State: Equatable {
        case loading
        case saved(count: Int)
        case failed(String)
    }

    private(set) var state: State = .loading

    func importImages(from providers: [NSItemProvider]) async {
        let imageProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        guard !imageProviders.isEmpty else {
            state = .failed("Folio can only import receipt images. Share a photo or screenshot of the receipt.")
            return
        }

        var pages: [Data] = []
        for provider in imageProviders {
            guard let raw = try? await Self.loadData(from: provider) else { continue }
            let jpeg = await Task.detached(priority: .userInitiated) {
                SharedReceiptInbox.normalizedJPEG(from: raw)
            }.value
            if let jpeg { pages.append(jpeg) }
        }

        guard !pages.isEmpty else {
            state = .failed("That image couldn't be read. Try a clearer photo of the receipt.")
            return
        }

        do {
            try SharedReceiptInbox.save(pages: pages)
            state = .saved(count: pages.count)
        } catch {
            state = .failed("Save failed: \(error)")
        }
    }

    private static func loadData(from provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }
}

struct ShareStatusView: View {
    let model: ShareModel
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch model.state {
            case .loading:
                ProgressView("Adding to Folio…")
                    .controlSize(.large)

            case .saved(let count):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Added to Folio")
                    .font(.title2.weight(.bold))
                Text(count == 1
                     ? "Open Folio and it will read the receipt for you to review."
                     : "\(count) pages added. Open Folio and it will read them for you to review.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Couldn't add receipt")
                    .font(.title3.weight(.bold))
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if model.state != .loading {
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
