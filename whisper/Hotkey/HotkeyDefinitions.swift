import AppKit
import Carbon.HIToolbox.Events
import os

private enum HotkeyEventFlags {
    static let alphaShift = CGEventFlags.maskAlphaShift.rawValue
    static let secondaryFn = CGEventFlags.maskSecondaryFn.rawValue

    // NX_DEVICE* masks live in bits 0-15 of CGEventFlags.rawValue.
    static let leftControl: UInt64 = 0x0000_0001
    static let leftShift: UInt64 = 0x0000_0002
    static let rightShift: UInt64 = 0x0000_0004
    static let leftCommand: UInt64 = 0x0000_0008
    static let rightCommand: UInt64 = 0x0000_0010
    static let leftOption: UInt64 = 0x0000_0020
    static let rightOption: UInt64 = 0x0000_0040
    static let rightControl: UInt64 = 0x0000_2000
}

enum HotkeyKeyCode {
    static let leftCommand = UInt16(kVK_Command)
    static let rightCommand = UInt16(kVK_RightCommand)
    static let leftShift = UInt16(kVK_Shift)
    static let rightShift = UInt16(kVK_RightShift)
    static let leftOption = UInt16(kVK_Option)
    static let rightOption = UInt16(kVK_RightOption)
    static let leftControl = UInt16(kVK_Control)
    static let rightControl = UInt16(kVK_RightControl)
    static let capsLock = UInt16(kVK_CapsLock)
    static let function = UInt16(kVK_Function)

    static let modifierCodes: Set<UInt16> = [
        leftCommand,
        rightCommand,
        leftShift,
        rightShift,
        leftOption,
        rightOption,
        leftControl,
        rightControl,
        capsLock,
        function,
    ]
}

struct HotkeyBinding: Codable, Hashable, Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "whisper",
        category: "HotkeyBinding"
    )
    private static let userDefaultsKey = "hotkeyBinding"
    private static let legacyPresetDefaultsKey = "hotkeyPreset"

    let keyCodes: [UInt16]

    static var defaultBinding: Self {
        .init(keyCodes: [HotkeyKeyCode.leftCommand, HotkeyKeyCode.leftControl])
    }

    var isEmpty: Bool {
        keyCodes.isEmpty
    }

    var keyCodeSet: Set<UInt16> {
        Set(keyCodes)
    }

    /// Whether this binding contains any non-modifier key codes (regular keys like A, Space, F1, etc.).
    var hasNonModifierKeys: Bool {
        keyCodes.contains { !HotkeyKeyCode.modifierCodes.contains($0) }
    }

    var displayLabel: String {
        guard !keyCodes.isEmpty else {
            return "Not Set"
        }

        return keyCodes
            .sorted(by: Self.displayOrder)
            .map(Self.displayName)
            .joined(separator: " + ")
    }

    init(keyCodes: [UInt16]) {
        self.keyCodes = Array(Set(keyCodes)).sorted()
    }

    init(keyCodes: Set<UInt16>) {
        self.init(keyCodes: Array(keyCodes))
    }

    static func load(defaults: UserDefaults = .standard) -> (binding: Self, fallbackMessage: String?) {
        if let encoded = defaults.data(forKey: userDefaultsKey) {
            do {
                let decoded = try JSONDecoder().decode(Self.self, from: encoded)
                if decoded.isEmpty {
                    return (defaultBinding, "Saved hotkey was empty. Using \(defaultBinding.displayLabel).")
                }
                return (decoded, nil)
            } catch {
                let fallback = defaultBinding
                fallback.save(defaults: defaults)
                return (fallback, "Saved hotkey was unreadable. Using \(fallback.displayLabel).")
            }
        }

        if let legacyPreset = defaults.string(forKey: legacyPresetDefaultsKey) {
            guard let migrated = legacyBinding(for: legacyPreset) else {
                let fallback = defaultBinding
                fallback.save(defaults: defaults)
                defaults.removeObject(forKey: legacyPresetDefaultsKey)
                return (fallback, "Saved hotkey preset is unsupported. Using \(fallback.displayLabel).")
            }

            migrated.save(defaults: defaults)
            defaults.removeObject(forKey: legacyPresetDefaultsKey)
            return (migrated, "Migrated push-to-talk shortcut to custom combo: \(migrated.displayLabel).")
        }

        return (defaultBinding, nil)
    }

    func save(defaults: UserDefaults = .standard) {
        do {
            let encoded = try JSONEncoder().encode(self)
            defaults.set(encoded, forKey: Self.userDefaultsKey)
            defaults.removeObject(forKey: Self.legacyPresetDefaultsKey)
        } catch {
            Self.logger.error("Failed to encode hotkey binding: \(error.localizedDescription, privacy: .public)")
            assertionFailure("HotkeyBinding encoding failed: \(error)")
        }
    }

    static func isModifierPressed(keyCode: UInt16, flagsRaw: UInt64) -> Bool {
        let deviceFlags = flagsRaw & 0xFFFF

        switch keyCode {
        case HotkeyKeyCode.leftControl:
            return (deviceFlags & HotkeyEventFlags.leftControl) != 0
        case HotkeyKeyCode.rightControl:
            return (deviceFlags & HotkeyEventFlags.rightControl) != 0
        case HotkeyKeyCode.leftShift:
            return (deviceFlags & HotkeyEventFlags.leftShift) != 0
        case HotkeyKeyCode.rightShift:
            return (deviceFlags & HotkeyEventFlags.rightShift) != 0
        case HotkeyKeyCode.leftCommand:
            return (deviceFlags & HotkeyEventFlags.leftCommand) != 0
        case HotkeyKeyCode.rightCommand:
            return (deviceFlags & HotkeyEventFlags.rightCommand) != 0
        case HotkeyKeyCode.leftOption:
            return (deviceFlags & HotkeyEventFlags.leftOption) != 0
        case HotkeyKeyCode.rightOption:
            return (deviceFlags & HotkeyEventFlags.rightOption) != 0
        case HotkeyKeyCode.capsLock:
            return (flagsRaw & HotkeyEventFlags.alphaShift) != 0
        case HotkeyKeyCode.function:
            return (flagsRaw & HotkeyEventFlags.secondaryFn) != 0
        default:
            return false
        }
    }

    private static func displayOrder(_ lhs: UInt16, _ rhs: UInt16) -> Bool {
        let leftRank = keyDisplayRank(of: lhs)
        let rightRank = keyDisplayRank(of: rhs)

        if leftRank == rightRank {
            return lhs < rhs
        }

        return leftRank < rightRank
    }

    private static func keyDisplayRank(of keyCode: UInt16) -> Int {
        switch keyCode {
        case HotkeyKeyCode.leftCommand, HotkeyKeyCode.rightCommand:
            return 0
        case HotkeyKeyCode.leftShift, HotkeyKeyCode.rightShift:
            return 1
        case HotkeyKeyCode.leftOption, HotkeyKeyCode.rightOption:
            return 2
        case HotkeyKeyCode.leftControl, HotkeyKeyCode.rightControl:
            return 3
        case HotkeyKeyCode.function:
            return 4
        case HotkeyKeyCode.capsLock:
            return 5
        default:
            return 10
        }
    }

    private static func legacyBinding(for presetRawValue: String) -> Self? {
        switch presetRawValue {
        case "leftCommandLeftControl":
            return .init(keyCodes: [HotkeyKeyCode.leftCommand, HotkeyKeyCode.leftControl])
        case "leftCommandLeftShift":
            return .init(keyCodes: [HotkeyKeyCode.leftCommand, HotkeyKeyCode.leftShift])
        case "leftCommandLeftOption":
            return .init(keyCodes: [HotkeyKeyCode.leftCommand, HotkeyKeyCode.leftOption])
        case "leftControlLeftOption":
            return .init(keyCodes: [HotkeyKeyCode.leftControl, HotkeyKeyCode.leftOption])
        case "leftOptionLeftShift":
            return .init(keyCodes: [HotkeyKeyCode.leftOption, HotkeyKeyCode.leftShift])
        default:
            return nil
        }
    }

    private static func displayName(for keyCode: UInt16) -> String {
        if let modifierLabel = modifierLabel(for: keyCode) {
            return modifierLabel
        }

        if let namedKey = namedKeyLabels[keyCode] {
            return namedKey
        }

        return "Key \(keyCode)"
    }

    private static func modifierLabel(for keyCode: UInt16) -> String? {
        switch keyCode {
        case HotkeyKeyCode.leftCommand:
            return "Left ⌘"
        case HotkeyKeyCode.rightCommand:
            return "Right ⌘"
        case HotkeyKeyCode.leftShift:
            return "Left ⇧"
        case HotkeyKeyCode.rightShift:
            return "Right ⇧"
        case HotkeyKeyCode.leftOption:
            return "Left ⌥"
        case HotkeyKeyCode.rightOption:
            return "Right ⌥"
        case HotkeyKeyCode.leftControl:
            return "Left ⌃"
        case HotkeyKeyCode.rightControl:
            return "Right ⌃"
        case HotkeyKeyCode.capsLock:
            return "Caps Lock"
        case HotkeyKeyCode.function:
            return "Fn"
        default:
            return nil
        }
    }

    private static let namedKeyLabels: [UInt16: String] = {
        var labels: [UInt16: String] = [
            UInt16(kVK_Return): "Return",
            UInt16(kVK_Tab): "Tab",
            UInt16(kVK_Space): "Space",
            UInt16(kVK_Delete): "Delete",
            UInt16(kVK_Escape): "Escape",
            UInt16(kVK_ForwardDelete): "Forward Delete",
            UInt16(kVK_Help): "Help",
            UInt16(kVK_Home): "Home",
            UInt16(kVK_End): "End",
            UInt16(kVK_PageUp): "Page Up",
            UInt16(kVK_PageDown): "Page Down",
            UInt16(kVK_LeftArrow): "Left Arrow",
            UInt16(kVK_RightArrow): "Right Arrow",
            UInt16(kVK_DownArrow): "Down Arrow",
            UInt16(kVK_UpArrow): "Up Arrow",
        ]

        let ansi: [(Int, String)] = [
            (kVK_ANSI_A, "A"),
            (kVK_ANSI_B, "B"),
            (kVK_ANSI_C, "C"),
            (kVK_ANSI_D, "D"),
            (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"),
            (kVK_ANSI_G, "G"),
            (kVK_ANSI_H, "H"),
            (kVK_ANSI_I, "I"),
            (kVK_ANSI_J, "J"),
            (kVK_ANSI_K, "K"),
            (kVK_ANSI_L, "L"),
            (kVK_ANSI_M, "M"),
            (kVK_ANSI_N, "N"),
            (kVK_ANSI_O, "O"),
            (kVK_ANSI_P, "P"),
            (kVK_ANSI_Q, "Q"),
            (kVK_ANSI_R, "R"),
            (kVK_ANSI_S, "S"),
            (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"),
            (kVK_ANSI_V, "V"),
            (kVK_ANSI_W, "W"),
            (kVK_ANSI_X, "X"),
            (kVK_ANSI_Y, "Y"),
            (kVK_ANSI_Z, "Z"),
            (kVK_ANSI_0, "0"),
            (kVK_ANSI_1, "1"),
            (kVK_ANSI_2, "2"),
            (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"),
            (kVK_ANSI_5, "5"),
            (kVK_ANSI_6, "6"),
            (kVK_ANSI_7, "7"),
            (kVK_ANSI_8, "8"),
            (kVK_ANSI_9, "9"),
            (kVK_ANSI_Minus, "-"),
            (kVK_ANSI_Equal, "="),
            (kVK_ANSI_LeftBracket, "["),
            (kVK_ANSI_RightBracket, "]"),
            (kVK_ANSI_Semicolon, ";"),
            (kVK_ANSI_Quote, "'"),
            (kVK_ANSI_Comma, ","),
            (kVK_ANSI_Period, "."),
            (kVK_ANSI_Slash, "/"),
            (kVK_ANSI_Backslash, "\\"),
            (kVK_ANSI_Grave, "`"),
        ]

        for (code, label) in ansi {
            labels[UInt16(code)] = label
        }

        // F-key codes are NOT sequential in Carbon; map each explicitly.
        let fKeys: [(Int, String)] = [
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"),
            (kVK_F5, "F5"), (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"),
            (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12"),
            (kVK_F13, "F13"), (kVK_F14, "F14"), (kVK_F15, "F15"), (kVK_F16, "F16"),
            (kVK_F17, "F17"), (kVK_F18, "F18"), (kVK_F19, "F19"), (kVK_F20, "F20"),
        ]
        for (code, label) in fKeys {
            labels[UInt16(code)] = label
        }

        return labels
    }()
}

/// Monitors for a configurable global key combo using a CGEvent tap.
/// Fires `onKeyDown` when the combo becomes fully held, `onKeyUp` when released.
///
/// Thread safety: All access is confined to the main thread. The CGEvent tap callback runs
/// on the main run loop, and callers access this class via `@State` (which is MainActor-isolated).
final class HotkeyMonitor {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var binding: HotkeyBinding = .defaultBinding {
        didSet {
            guard binding != oldValue else { return }

            // Restart tap if the required event mask changed (e.g. modifier-only vs. has regular keys).
            let needsRegularKeys = binding.hasNonModifierKeys
            let hadRegularKeys = oldValue.hasNonModifierKeys
            if eventTap != nil && needsRegularKeys != hadRegularKeys {
                stop()
                start()
            }

            updateHeldStateAndCallbacks()
        }
    }

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    fileprivate var pressedKeyCodes: Set<UInt16> = []
    private(set) var isHeld = false

    func start() {
        guard eventTap == nil else { return }

        // Only intercept keyDown/keyUp when the binding includes non-modifier keys.
        // This avoids adding overhead to every keystroke system-wide for modifier-only combos.
        var mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        if binding.hasNonModifierKeys {
            mask |= (1 << CGEventType.keyDown.rawValue)
            mask |= (1 << CGEventType.keyUp.rawValue)
        }

        // Use a weak reference via an Unmanaged pointer so the callback can reach us.
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: refcon
        ) else {
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        pressedKeyCodes.removeAll()

        if isHeld {
            isHeld = false
            onKeyUp?()
        }
    }

    deinit {
        stop()
    }

    /// Called from the C callback on the main run loop.
    fileprivate func handleKeyboardEvent(type: CGEventType, event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        switch type {
        case .keyDown:
            pressedKeyCodes.insert(keyCode)
        case .keyUp:
            pressedKeyCodes.remove(keyCode)
        case .flagsChanged:
            guard HotkeyKeyCode.modifierCodes.contains(keyCode) else {
                return
            }

            let isPressed = HotkeyBinding.isModifierPressed(
                keyCode: keyCode,
                flagsRaw: event.flags.rawValue
            )

            if isPressed {
                pressedKeyCodes.insert(keyCode)
            } else {
                pressedKeyCodes.remove(keyCode)
            }
        default:
            return
        }

        updateHeldStateAndCallbacks()
    }

    fileprivate func updateHeldStateAndCallbacks() {
        let shouldBeHeld = !binding.isEmpty && pressedKeyCodes == binding.keyCodeSet

        if shouldBeHeld && !isHeld {
            isHeld = true
            onKeyDown?()
        } else if !shouldBeHeld && isHeld {
            isHeld = false
            onKeyUp?()
        }
    }
}

/// C function callback for the CGEvent tap.
/// Runs on the main run loop (same thread as all HotkeyMonitor access).
private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    _ = proxy

    // Handle tap being disabled by the system (e.g. timeout).
    // Clear pressed-key state because we may have missed key-up events during the gap.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let refcon = refcon {
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.pressedKeyCodes.removeAll()
            monitor.updateHeldStateAndCallbacks()
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard
        let refcon,
        type == .flagsChanged || type == .keyDown || type == .keyUp
    else {
        return Unmanaged.passUnretained(event)
    }

    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    monitor.handleKeyboardEvent(type: type, event: event)

    return Unmanaged.passUnretained(event)
}
