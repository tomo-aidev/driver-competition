import SwiftUI
import PhotosUI

/// Wraps PHPickerViewController for video selection
struct VideoPicker: UIViewControllerRepresentable {
    @Binding var selectedVideoURL: URL?
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: VideoPicker

        init(_ parent: VideoPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let result = results.first else {
                parent.dismiss()
                return
            }

            let provider = result.itemProvider
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, error in
                    guard let url, error == nil else {
                        DispatchQueue.main.async { self?.parent.dismiss() }
                        return
                    }

                    // Copy to temporary location (provider URL is ephemeral)
                    let tempDir = FileManager.default.temporaryDirectory
                    let destURL = tempDir.appendingPathComponent(UUID().uuidString + ".mov")
                    try? FileManager.default.copyItem(at: url, to: destURL)

                    DispatchQueue.main.async {
                        self?.parent.selectedVideoURL = destURL
                        self?.parent.dismiss()
                    }
                }
            } else {
                parent.dismiss()
            }
        }
    }
}
