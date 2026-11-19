import AppKit
import SwiftUI

/// Manages the lifecycle of the floating recording indicator panel.
/// Reuses a single `FloatingPanel` instance across recordings to avoid
/// repeatedly allocating `NSPanel`, `NSHostingView`, and Metal surfaces.
@MainActor
final class OverlayManager {
    private var panel: FloatingPanel<RecordingOverlayView>?
    private var isPresented = false
    private let overlaySize = CGSize(
        width: RecordingOverlayView.circleDiameter,
        height: RecordingOverlayView.circleDiameter
    )

    func show(appState: AppState) {
        if panel == nil {
            let contentRect = NSRect(origin: .zero, size: overlaySize)
            panel = FloatingPanel(
                rootView: RecordingOverlayView(appState: appState),
                contentRect: contentRect
            )
        }

        guard let panel else { return }

        if !isPresented {
            panel.positionBottomCenter()
            isPresented = true
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        guard isPresented else { return }
        isPresented = false
        panel?.orderOut(nil)
    }
}
