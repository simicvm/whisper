import AppKit

private enum ModifierHotkeyFlags {
    static let control = CGEventFlags.maskControl.rawValue
    static let command = CGEventFlags.maskCommand.rawValue
    static let shift = CGEventFlags.maskShift.rawValue
    static let option = CGEventFlags.maskAlternate.rawValue

    // NX_DEVICE* masks live in bits 0-15 of CGEventFlags.rawValue.
    static let leftControl: UInt64 = 0x0000_0001
    static let leftShift: UInt64 = 0x0000_0002
    static let leftCommand: UInt64 = 0x0000_0008
    static let leftOption: UInt64 = 0x0000_0020

    // Intentionally track only command/control/shift/option.
    // Fn/Caps Lock are ignored so they do not block activation.
    static let standardModifierMask = control | command | shift | option
}

enum ModifierHotkeyPreset: String, CaseIterable, Codable, Hashable, Identifiable {
    case leftCommandLeftControl
    case leftCommandLeftShift
    case leftCommandLeftOption
    case leftControlLeftOption
    case leftOptionLeftShift

    static let userDefaultsKey = "hotkeyPreset"

    static var defaultPreset: Self { .leftCommandLeftControl }

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .leftCommandLeftControl:
            return "Left ⌘ + Left ⌃"
        case .leftCommandLeftShift:
            return "Left ⌘ + Left ⇧"
        case .leftCommandLeftOption:
            return "Left ⌘ + Left ⌥"
        case .leftControlLeftOption:
            return "Left ⌃ + Left ⌥"
        case .leftOptionLeftShift:
            return "Left ⌥ + Left ⇧"
        }
    }

    fileprivate var requiredStandardFlags: UInt64 {
        switch self {
        case .leftCommandLeftControl:
            return ModifierHotkeyFlags.command | ModifierHotkeyFlags.control
        case .leftCommandLeftShift:
            return ModifierHotkeyFlags.command | ModifierHotkeyFlags.shift
        case .leftCommandLeftOption:
            return ModifierHotkeyFlags.command | ModifierHotkeyFlags.option
        case .leftControlLeftOption:
            return ModifierHotkeyFlags.control | ModifierHotkeyFlags.option
        case .leftOptionLeftShift:
            return ModifierHotkeyFlags.option | ModifierHotkeyFlags.shift
        }
    }

    fileprivate var requiredDeviceFlags: UInt64 {
        switch self {
        case .leftCommandLeftControl:
            return ModifierHotkeyFlags.leftCommand | ModifierHotkeyFlags.leftControl
        case .leftCommandLeftShift:
            return ModifierHotkeyFlags.leftCommand | ModifierHotkeyFlags.leftShift
        case .leftCommandLeftOption:
            return ModifierHotkeyFlags.leftCommand | ModifierHotkeyFlags.leftOption
        case .leftControlLeftOption:
            return ModifierHotkeyFlags.leftControl | ModifierHotkeyFlags.leftOption
        case .leftOptionLeftShift:
            return ModifierHotkeyFlags.leftOption | ModifierHotkeyFlags.leftShift
        }
    }

    static func load(defaults: UserDefaults = .standard) -> (preset: Self, fallbackMessage: String?) {
        guard let rawValue = defaults.string(forKey: userDefaultsKey) else {
            return (defaultPreset, nil)
        }

        guard let preset = Self(rawValue: rawValue) else {
            return (
                defaultPreset,
                "Saved hotkey is unsupported. Using \(defaultPreset.displayLabel)."
            )
        }

        return (preset, nil)
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.userDefaultsKey)
    }
}

/// Monitors for a configurable modifier-only hotkey using a CGEvent tap.
/// Fires `onKeyDown` when all required modifiers are pressed, `onKeyUp` when released.
@Observable
final class ModifierHotkeyMonitor {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var preset: ModifierHotkeyPreset = .defaultPreset {
        didSet {
            guard preset != oldValue else { return }
            let wasHeld = isHeld
            isHeld = false
            if wasHeld {
                onKeyUp?()
            }
        }
    }

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isHeld = false

    func start() {
        guard eventTap == nil else { return }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        // Use a weak reference via an Unmanaged pointer so the callback can reach us.
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: modifierCallback,
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
        isHeld = false
    }

    deinit {
        stop()
    }

    /// Called from the C callback on the main run loop.
    fileprivate func handleFlagsChanged(_ flags: CGEventFlags) {
        let raw = flags.rawValue

        // Require an exact match for tracked modifier keys.
        // Fn/Caps Lock are intentionally ignored by the shared mask.
        let standardFlags = raw & ModifierHotkeyFlags.standardModifierMask

        // Check device-specific flags to distinguish left vs right.
        // NX_DEVICE* masks live in bits 0-15 of CGEventFlags.rawValue.
        let deviceFlags = raw & 0xFFFF
        let requiredStandardFlags = preset.requiredStandardFlags
        let requiredDeviceFlags = preset.requiredDeviceFlags

        let hasExactModifiers = standardFlags == requiredStandardFlags
        let hasRequiredLeftModifiers = (deviceFlags & requiredDeviceFlags) == requiredDeviceFlags
        let bothHeld = hasExactModifiers && hasRequiredLeftModifiers

        if bothHeld && !isHeld {
            isHeld = true
            onKeyDown?()
        } else if !bothHeld && isHeld {
            isHeld = false
            onKeyUp?()
        }
    }
}

/// C function callback for the CGEvent tap.
private func modifierCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Handle tap being disabled by the system (e.g. timeout)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let refcon = refcon {
            let monitor = Unmanaged<ModifierHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .flagsChanged, let refcon = refcon else {
        return Unmanaged.passUnretained(event)
    }

    let monitor = Unmanaged<ModifierHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    monitor.handleFlagsChanged(event.flags)

    return Unmanaged.passUnretained(event)
}
