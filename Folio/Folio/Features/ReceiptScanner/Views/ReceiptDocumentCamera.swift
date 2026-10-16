//
//  ReceiptDocumentCamera.swift
//  Folio
//
//  Created by Divy Patel on 16/10/2026.
//
import Foundation
import SwiftUI
import VisionKit

struct ReceiptDocumentCamera: UIViewControllerRepresentable {
    let onScan: ([Data]) -> Void
    let onCancel: () -> Void
    let onError: (Error) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let camera = VNDocumentCameraViewController()
        camera.delegate = context.coordinator
        return camera
    }

    func updateUIViewController(
        _ controller: VNDocumentCameraViewController,
        context: Context
    ) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        private let parent: ReceiptDocumentCamera

        init(_ parent: ReceiptDocumentCamera) {
            self.parent = parent
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var pages: [Data] = []

            for index in 0..<scan.pageCount {
                guard let data = scan.imageOfPage(at: index)
                    .jpegData(compressionQuality: 0.95) else {
                    controller.dismiss(animated: true) {
                        self.parent.onError(ScannerError.imageConversionFailed)
                    }
                    return
                }
                pages.append(data)
            }

            controller.dismiss(animated: true) {
                self.parent.onScan(pages)
            }
        }

        func documentCameraViewControllerDidCancel(
            _ controller: VNDocumentCameraViewController
        ) {
            controller.dismiss(animated: true) {
                self.parent.onCancel()
            }
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            controller.dismiss(animated: true) {
                self.parent.onError(error)
            }
        }
    }
}
