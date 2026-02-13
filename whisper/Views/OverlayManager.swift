import AppKit
import SwiftUI

/// Manages the lifecycle of the floating recording indicator panel.
@MainActor
final class OverlayManager {
    private var panel: FloatingPanel<RecordingOverlayView>?
    private var isPresented = false
    private let overlaySize = CGSize(width: RecordingOverlayView.circleDiameter, height: RecordingOverlayView.circleDiameter)

    func show(appState: AppState) {
        if panel == nil {
            let binding = Binding<Bool>(
                get: { [weak self] in
                    self?.isPresented ?? false
                },
                set: { [weak self] newValue in
                    guard let self else { return }
                    self.isPresented = newValue
                    if !newValue {
                        self.panel = nil
                    }
                }
            )

            let contentRect = NSRect(origin: .zero, size: overlaySize)
            let newPanel = FloatingPanel(
                view: {
                    RecordingOverlayView(appState: appState)
                },
                contentRect: contentRect,
                isPresented: binding
            )
            newPanel.positionBottomCenter()
            panel = newPanel
        } else {
            panel?.updateView {
                RecordingOverlayView(appState: appState)
            }
        }

        isPresented = true
        panel?.orderFrontRegardless()
    }

    func hide() {
        isPresented = false
        panel?.close()
        panel = nil
    }
}
