import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// 基于 PHPickerViewController 的媒体选择器（iOS 15 可用）
struct MediaPicker: UIViewControllerRepresentable {

    enum Kind {
        case image
        case video

        var filter: PHPickerFilter {
            switch self {
            case .image: return .images
            case .video: return .videos
            }
        }

        var typeIdentifier: String {
            switch self {
            case .image: return UTType.image.identifier
            case .video: return UTType.movie.identifier
            }
        }
    }

    var kind: Kind
    var onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = kind.filter
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(kind: kind, onPick: onPick)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let kind: Kind
        private let onPick: (URL?) -> Void

        init(kind: Kind, onPick: @escaping (URL?) -> Void) {
            self.kind = kind
            self.onPick = onPick
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let item = results.first?.itemProvider else {
                onPick(nil)
                return
            }
            let identifier = kind.typeIdentifier
            guard item.hasItemConformingToTypeIdentifier(identifier) else {
                onPick(nil)
                return
            }
            item.loadFileRepresentation(forTypeIdentifier: identifier) { [weak self] url, _ in
                DispatchQueue.main.async {
                    self?.onPick(url)
                }
            }
        }
    }
}
