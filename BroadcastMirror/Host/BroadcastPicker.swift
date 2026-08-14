import SwiftUI
import ReplayKit
import UIKit

/// Wraps `RPSystemBroadcastPickerView` and programmatically taps its button on
/// appear so the system broadcast sheet opens without a human tap. The farm then
/// taps "Start Broadcast" on the sheet. Retries a few times because the picker's
/// internal `UIButton` is not always in the view tree on the first layout pass.
struct BroadcastPicker: UIViewRepresentable {
    /// The upload extension the picker should pre-select. Coordinated with bmfarm.
    static let uploadExtensionID = "net.busymate.mirror.upload"

    let preferredExtension: String

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        picker.preferredExtension = preferredExtension
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        guard !context.coordinator.didOpen else { return }
        openWhenReady(uiView, coordinator: context.coordinator, attempt: 0)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var didOpen = false }

    private func openWhenReady(_ view: RPSystemBroadcastPickerView, coordinator: Coordinator, attempt: Int) {
        guard attempt < 8, !coordinator.didOpen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.8 : 0.4)) {
            if let button = view.subviews.compactMap({ $0 as? UIButton }).first {
                coordinator.didOpen = true
                button.sendActions(for: .touchUpInside)
            } else {
                openWhenReady(view, coordinator: coordinator, attempt: attempt + 1)
            }
        }
    }
}
