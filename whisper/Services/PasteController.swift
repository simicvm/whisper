import AppKit
import Carbon.HIToolbox

/// Pastes text into the frontmost application by writing to the pasteboard
/// and simulating Cmd+V.
@MainActor
struct PasteController {

    /// Time to wait after simulating Cmd+V before restoring the original clipboard.
    /// Runs asynchronously in the background so the app returns to idle right
    /// after Cmd+V is posted.
    private static let pasteCompletionDelay: Duration = .milliseconds(400)

    /// Brief gap between the Cmd+V key-down and key-up events so the target
    /// application reliably registers the keystroke.
    private static let keyEventGap: Duration = .milliseconds(10)

    /// Maximum time to wait for physically held modifier keys to be released
    /// before simulating Cmd+V anyway.
    private static let modifierReleaseTimeout: Duration = .seconds(2)

    /// Maximum character count for falling back to `kAXValueAttribute` when a
    /// focused element does not support `kAXStringForRangeParameterizedAttribute`.
    private static let maxFallbackAXCharacterCount = 10_000

    /// Upper bound on total clipboard bytes snapshotted before pasting so huge
    /// images or rich documents don't stall the main thread or bloat memory.
    private static let maxSnapshotBytes = 10 * 1024 * 1024

    private static var pendingRestoreTask: Task<Void, Never>?
    private static var pendingRestoreState: (snapshot: PasteboardSnapshot, expectedChangeCount: Int)?

    /// Paste text into the active application.
    /// Saves and restores the original clipboard contents asynchronously so
    /// the caller does not block waiting for the restore window.
    static func paste(_ text: String) async throws {
        guard hasAccessibilityPermission else {
            throw PasteError.accessibilityPermissionRequired
        }

        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general

        // If a previous dictation's restore is still pending and nothing else
        // modified the clipboard, reuse the original pre-dictation snapshot.
        let snapshot: PasteboardSnapshot
        if let pending = pendingRestoreState, pasteboard.changeCount == pending.expectedChangeCount {
            pendingRestoreTask?.cancel()
            pendingRestoreTask = nil
            pendingRestoreState = nil
            snapshot = pending.snapshot
        } else {
            pendingRestoreTask?.cancel()
            pendingRestoreTask = nil
            pendingRestoreState = nil
            snapshot = capturePasteboardSnapshot(from: pasteboard)
        }

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

        // Restore original pasteboard in the background after the target app
        // has had time to consume Cmd+V, without blocking the next dictation.
        schedulePasteboardRestore(snapshot: snapshot, expectedChangeCount: stagedChangeCount)
    }

    private static func schedulePasteboardRestore(
        snapshot: PasteboardSnapshot,
        expectedChangeCount: Int
    ) {
        pendingRestoreTask?.cancel()
        pendingRestoreState = (snapshot, expectedChangeCount)
        pendingRestoreTask = Task { @MainActor in
            do {
                try await Task.sleep(for: pasteCompletionDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            restorePasteboard(
                snapshot,
                to: NSPasteboard.general,
                expectedChangeCount: expectedChangeCount
            )
            if pendingRestoreState?.expectedChangeCount == expectedChangeCount {
                pendingRestoreState = nil
                pendingRestoreTask = nil
            }
        }
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

        // Read the selected text range (cursor position) FIRST so we avoid
        // fetching any text at all when the cursor is at index 0.
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
        guard cursorPosition > 0 else {
            return false
        }

        // Fast O(1) path: request only the 1–2 UTF-16 code units right before
        // the cursor (2 units cover both BMP characters and surrogate pairs).
        let prefixLength = min(2, cursorPosition)
        var prefixRange = CFRange(location: cursorPosition - prefixLength, length: prefixLength)
        if let axPrefixRange = AXValueCreate(.cfRange, &prefixRange) {
            var prefixRef: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                axPrefixRange,
                &prefixRef
            ) == .success,
               let prefixText = prefixRef as? String,
               let charBeforeCursor = prefixText.last {
                return !charBeforeCursor.isWhitespace
            }
        }

        // Fallback for elements that don't support parameterized range queries:
        // bail out if the document is large so we never pull megabytes over IPC.
        var charCountRef: AnyObject?
        if AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &charCountRef
        ) == .success,
           let charCount = charCountRef as? Int,
           charCount > maxFallbackAXCharacterCount {
            return false
        }

        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success,
              let text = valueRef as? String,
              !text.isEmpty,
              cursorPosition <= text.utf16.count
        else {
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

    /// Standard macOS pasteboard marker types recognized by clipboard managers
    /// (Raycast, Alfred, Maccy, Paste, 1Password, etc.).
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private static func writeText(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        item.setData(Data(), forType: autoGeneratedType)
        return pasteboard.writeObjects([item])
    }

    /// Pasteboard types whose data is promised rather than materialised.
    /// Reading them with data(forType:) forces the source application to
    /// resolve the promise synchronously, which can block the main thread
    /// for a long time — and a promise is meaningless to restore once its
    /// source context is gone. Skip them when snapshotting.
    private static let promisedDataTypes: Set<String> = {
        var types = Set(NSFilePromiseReceiver.readableDraggedTypes)
        // Legacy NSFilesPromisePboardType, still emitted by some apps.
        types.insert("Apple files promise pasteboard type")
        return types
    }()

    private static func capturePasteboardSnapshot(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        var totalBytes = 0
        var snapshots: [PasteboardItemSnapshot] = []

        for item in pasteboard.pasteboardItems ?? [] {
            // Never capture concealed (password manager) or transient pasteboard items.
            let types = item.types
            if types.contains(concealedType) || types.contains(transientType) {
                continue
            }

            // Skip uncompressed TIFF when PNG is already offered on the same
            // item — rasterizing a TIFF can stall the source app and multiply RAM.
            let hasPNG = types.contains(.png)
            var payloads: [PasteboardPayload] = []

            for type in types {
                guard !promisedDataTypes.contains(type.rawValue) else { continue }
                if hasPNG && type == .tiff { continue }
                guard let data = item.data(forType: type) else { continue }
                guard totalBytes + data.count <= maxSnapshotBytes else { continue }
                totalBytes += data.count
                payloads.append(PasteboardPayload(type: type, data: data))
            }

            if !payloads.isEmpty {
                snapshots.append(PasteboardItemSnapshot(payloads: payloads))
            }
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
            // Mark restored items transient so clipboard history managers don't
            // log a duplicate entry for the user's original clipboard contents.
            item.setData(Data(), forType: transientType)
            item.setData(Data(), forType: autoGeneratedType)
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

    /// Resolves the virtual key code for `"v"` in the active ASCII-capable
    /// keyboard layout so Cmd+V works on Dvorak and other non-QWERTY layouts
    /// (as well as non-Latin layouts, where macOS routes Cmd shortcuts through
    /// the ASCII-capable layout).
    internal static func resolvePasteKeyCode() -> CGKeyCode {
        guard let inputSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return CGKeyCode(kVK_ANSI_V)
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayoutData).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())

        func translatesToV(keyCode: UInt16, in layoutPtr: UnsafePointer<UCKeyboardLayout>) -> Bool {
            var deadKeyState: UInt32 = 0
            var chars: [UniChar] = [0, 0, 0, 0]
            var actualLength = 0
            let status = UCKeyTranslate(
                layoutPtr,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                keyboardType,
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &actualLength,
                &chars
            )
            guard status == noErr, actualLength == 1 else { return false }
            return chars[0] == 0x76 || chars[0] == 0x56 // 'v' or 'V'
        }

        return layoutData.withUnsafeBytes { rawBuffer -> CGKeyCode in
            guard let layoutPtr = rawBuffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return CGKeyCode(kVK_ANSI_V)
            }

            // Fast path: ANSI QWERTY/AZERTY/QWERTZ/Colemak keep V at kVK_ANSI_V.
            if translatesToV(keyCode: UInt16(kVK_ANSI_V), in: layoutPtr) {
                return CGKeyCode(kVK_ANSI_V)
            }

            for candidate: UInt16 in 0..<128 where candidate != UInt16(kVK_ANSI_V) {
                if translatesToV(keyCode: candidate, in: layoutPtr) {
                    return CGKeyCode(candidate)
                }
            }
            return CGKeyCode(kVK_ANSI_V)
        }
    }

    private static func simulateCmdV() async throws {
        let vKeyCode = resolvePasteKeyCode()
        // Use an isolated private event source so lingering hardware modifier
        // flags do not merge into the synthetic Cmd+V event.
        let eventSource = CGEventSource(stateID: .privateState)

        // Key down
        guard let keyDown = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: vKeyCode,
            keyDown: true
        ) else {
            throw PasteError.keyEventCreationFailed
        }
        keyDown.flags = .maskCommand
        keyDown.setIntegerValueField(.eventSourceUserData, value: WhisperSyntheticEvent.userDataTag)
        keyDown.post(tap: .cghidEventTap)

        // Brief delay between down and up
        try? await Task.sleep(for: keyEventGap)

        // Key up
        guard let keyUp = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: vKeyCode,
            keyDown: false
        ) else {
            throw PasteError.keyEventCreationFailed
        }
        keyUp.flags = .maskCommand
        keyUp.setIntegerValueField(.eventSourceUserData, value: WhisperSyntheticEvent.userDataTag)
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
