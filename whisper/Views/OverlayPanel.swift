import AppKit
import SwiftUI

/// A floating, non-activating borderless panel reused across recordings.
final class FloatingPanel<Content: View>: NSPanel {
    private let hostingView: NSHostingView<Content>

    init(
        rootView: Content,
        contentRect: NSRect
    ) {
        self.hostingView = NSHostingView(rootView: rootView)

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

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    /// Position the panel at the bottom-center of the active screen (the screen
    /// containing the cursor, falling back to the main screen).
    func positionBottomCenter() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - (frame.width / 2)
        let y = screenFrame.minY + 15
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }
}
