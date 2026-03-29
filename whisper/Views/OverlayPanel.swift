import AppKit
import SwiftUI

/// A floating, non-activating panel adapted from a blog-style NSPanel implementation.
final class FloatingPanel: NSPanel {
    @Binding private var isPresented: Bool
    private let hostingView: NSHostingView<AnyView>

    init(
        @ViewBuilder view: () -> some View,
        contentRect: NSRect,
        isPresented: Binding<Bool>
    ) {
        self._isPresented = isPresented
        self.hostingView = NSHostingView(rootView: AnyView(view()))

        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        animationBehavior = .utilityWindow
        isMovableByWindowBackground = false
        hidesOnDeactivate = false

        isOpaque = false
        hostingView.layer?.isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        ignoresMouseEvents = true
        hasShadow = false

        contentView = hostingView
    }

    func updateView(@ViewBuilder _ view: () -> some View) {
        hostingView.rootView = AnyView(view())
    }

    override func resignMain() {
        super.resignMain()
        close()
    }

    override func close() {
        super.close()
        isPresented = false
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    /// Position the panel at the bottom-center of the main screen.
    func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - (frame.width / 2)
        let y = screenFrame.minY + 15
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }
}
