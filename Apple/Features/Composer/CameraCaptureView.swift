#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import AtmoCore

// MARK: - Camera Capture View
/// The composer's camera: the system capture UI (photo + video, with its
/// own mode switch, flash, and camera-flip controls) wrapped for SwiftUI.
/// Deliberately basic — capture lands back in the composer as an
/// attachment; the composer owns saving, previewing, and publishing.
struct CameraCaptureView: UIViewControllerRepresentable {

    enum Capture {
        case photo(UIImage)
        /// The system's temp movie file — COPY IT before this call returns;
        /// the file dies with the camera UI.
        case video(URL)
    }

    /// Called on the main actor right before the camera dismisses.
    let onCapture: (Capture) -> Void

    @Environment(\.dismiss) private var dismiss

    /// No camera, no button (Simulator, some iPads).
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.videoQuality = .typeHigh
        // The capture UI enforces Bluesky's clip cap so an overlong take
        // can't even be recorded.
        picker.videoMaximumDuration = VideoConstraints.maxDuration
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraCaptureView

        init(_ parent: CameraCaptureView) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            // onCapture runs BEFORE dismissal so a video handler can copy
            // the temp file while it still exists.
            if let movieURL = info[.mediaURL] as? URL {
                parent.onCapture(.video(movieURL))
            } else if let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage) {
                parent.onCapture(.photo(image))
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif
