import AppKit
import Carbon.HIToolbox

/// Pastes text into the frontmost application by writing to the pasteboard
/// and simulating Cmd+V.
@MainActor
struct PasteController {

    /// Time to wait after writing to the pasteboard before simulating Cmd+V.
    /// Gives the system pasteboard server time to propagate the change.
    private static let pasteboardSettleDelay: Duration = .milliseconds(50)

    /// Time to wait after simulating Cmd+V before restoring the original clipboard.
    /// Must be long enough for the target application to read the pasteboard.
    /// Slow consumers (rich text editors, remote desktop clients) may need more.
    private static let pasteCompletionDelay: Duration = .milliseconds(400)

    /// Brief gap between the Cmd+V key-down and key-up events so the target
    /// application reliably registers the keystroke.
    private static let keyEventGap: Duration = .milliseconds(10)

    /// Maximum time to wait for physically held modifier keys to be released
    /// before simulating Cmd+V anyway.
    private static let modifierReleaseTimeout: Duration = .seconds(2)

    /// Paste text into the active application.
    /// Saves and restores the original clipboard contents.
    static func paste(_ text: String) async throws {
        guard hasAccessibilityPermission else {
            throw PasteError.accessibilityPermissionRequired
        }

        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let snapshot = capturePasteboardSnapshot(from: pasteboard)

        // Prepend a space if the cursor sits right after non-whitespace text
        let finalText = shouldPrependSpace() ? " \(text)" : text

        guard writeText(finalText, to: pasteboard) else {
            // Nothing useful is on the pasteboard now (write cleared it),
            // so put the user's original contents back.
            restorePasteboard(
                snapshot,
                to: pasteboard,
                expectedChangeCount: pasteboard.changeCount
            )
            throw PasteError.pasteboardWriteFailed
        }

        let stagedChangeCount = pasteboard.changeCount

        // Small delay to ensure pasteboard is updated
        try? await Task.sleep(for: pasteboardSettleDelay)

        // The push-to-talk combo is modifier-based, so for fast transcriptions
        // (or the max-duration timeout) we can get here while the user still
        // holds part of the combo. The hardware modifier state can then merge
        // into the synthetic keystroke — the target app sees e.g. ⌃⌘V instead
        // of ⌘V and the paste silently does nothing. Wait for a clean state.
        await waitForPhysicalModifierRelease()

        // Simulate Cmd+V keystroke. On failure, deliberately skip the
        // restore: the transcription would otherwise be lost entirely.
        // Leaving it on the pasteboard lets the user paste it manually.
        try await simulateCmdV()

        // Restore original pasteboard after paste completes
        try? await Task.sleep(for: pasteCompletionDelay)
        restorePasteboard(
            snapshot,
            to: pasteboard,
            expectedChangeCount: stagedChangeCount
        )
    }

    /// Check if the app has Accessibility permission (required for CGEvent posting).
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant Accessibility permission.
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Private

    /// Check whether the focused text field already has non-whitespace text
    /// immediately before the cursor, meaning we should prepend a space to the
    /// transcribed text so it doesn't jam against existing content.
    private static func shouldPrependSpace() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        // Get the currently focused UI element
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
              let focusedRef
        else {
            return false
        }
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return false
        }
        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)

        // Read the element's text value
        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success,
              let text = valueRef as? String,
              !text.isEmpty
        else {
            return false
        }

        // Read the selected text range (cursor position)
        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
              let rangeRef
        else {
            return false
        }
        guard CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            return false
        }
        let rangeValue = unsafeBitCast(rangeRef, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else {
            return false
        }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue, .cfRange, &range) else {
            return false
        }

        let cursorPosition = range.location
        guard cursorPosition > 0, cursorPosition <= text.utf16.count else {
            return false
        }

        // Convert the UTF-16 offset from the AX API into a proper String.Index.
        // This correctly handles multi-code-unit characters (emoji, CJK, etc.)
        // that are represented as surrogate pairs in UTF-16.
        let utf16View = text.utf16
        let cursorUTF16Index = utf16View.index(utf16View.startIndex, offsetBy: cursorPosition)

        guard let stringIndex = cursorUTF16Index.samePosition(in: text),
              stringIndex > text.startIndex else {
            // Cursor is between the two halves of a surrogate pair, meaning
            // the character is non-BMP (emoji, etc.) which is never whitespace.
            return true
        }

        let charBeforeCursor = text[text.index(before: stringIndex)]
        return !charBeforeCursor.isWhitespace
    }

    private static func writeText(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private static func capturePasteboardSnapshot(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let snapshots = (pasteboard.pasteboardItems ?? []).map { item in
            let payloads = item.types.compactMap { type -> PasteboardPayload? in
                guard let data = item.data(forType: type) else { return nil }
                return PasteboardPayload(type: type, data: data)
            }
            return PasteboardItemSnapshot(payloads: payloads)
        }

        return PasteboardSnapshot(items: snapshots)
    }

    private static func restorePasteboard(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard,
        expectedChangeCount: Int
    ) {
        guard pasteboard.changeCount == expectedChangeCount else {
            return
        }

        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else {
            return
        }

        let restoredItems: [NSPasteboardItem] = snapshot.items.compactMap { snapshotItem in
            guard !snapshotItem.payloads.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for payload in snapshotItem.payloads {
                item.setData(payload.data, forType: payload.type)
            }
            return item
        }

        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }

    /// Wait (bounded by `modifierReleaseTimeout`) until no modifier keys are
    /// physically held. Caps Lock is excluded: its flag reflects the latched
    /// lock state, not a held key, and would stall every paste while enabled.
    private static func waitForPhysicalModifierRelease() async {
        let watched: CGEventFlags = [
            .maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn,
        ]
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: modifierReleaseTimeout)

        while clock.now < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(watched).isEmpty {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func simulateCmdV() async throws {
        let vKeyCode: CGKeyCode = CGKeyCode(kVK_ANSI_V)

        // Key down
        guard let keyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: vKeyCode,
            keyDown: true
        ) else {
            throw PasteError.keyEventCreationFailed
        }
        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)

        // Brief delay between down and up
        try? await Task.sleep(for: keyEventGap)

        // Key up
        guard let keyUp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: vKeyCode,
            keyDown: false
        ) else {
            throw PasteError.keyEventCreationFailed
        }
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)
    }

    private struct PasteboardSnapshot {
        let items: [PasteboardItemSnapshot]
    }

    private struct PasteboardItemSnapshot {
        let payloads: [PasteboardPayload]
    }

    private struct PasteboardPayload {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }
}

enum PasteError: LocalizedError {
    case accessibilityPermissionRequired
    case pasteboardWriteFailed
    case keyEventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "Accessibility permission is required to paste text"
        case .pasteboardWriteFailed:
            return "Unable to write text to the pasteboard"
        case .keyEventCreationFailed:
            return "Could not simulate Cmd+V. The text is on your clipboard — paste it manually."
        }
    }
}
