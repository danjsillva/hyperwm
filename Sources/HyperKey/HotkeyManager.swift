import Cocoa
import Carbon
import IOKit

// Global storage for hotkey specs (accessed from C callback)
private var globalHotkeys: [HotkeyManager.HotkeySpec] = []
private var globalUseBuiltInHyper: Bool = false

// F18 as Hyper key (Caps Lock is remapped to F18 via hidutil)
private let kF18KeyCode: UInt16 = 79  // F18 keycode on macOS
private var hyperKeyDown: Bool = false  // True when F18/Caps Lock is held
private var hyperKeyUsedAsModifier: Bool = false
private var hyperKeyPressTime: UInt64 = 0
private let tapThresholdNs: UInt64 = 200_000_000  // 200ms - tap vs hold threshold
private var capsLockEnabled: Bool = false  // Track Caps Lock state ourselves

class HotkeyManager {
    typealias HotkeyHandler = (String) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hotkeys: [HotkeySpec] = []
    private let handler: HotkeyHandler

    // Built-in Hyper key support (uses hidutil to remap Caps Lock → F18)
    var useBuiltInHyper: Bool = false {
        didSet {
            globalUseBuiltInHyper = useBuiltInHyper
            if useBuiltInHyper {
                setupHidutil()
            } else {
                clearHidutil()
            }
            restartEventTap()
        }
    }

    struct HotkeySpec {
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        let id: String
    }

    init(handler: @escaping HotkeyHandler) {
        self.handler = handler

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHotkeyNotification),
            name: .hotkeyPressed,
            object: nil
        )
    }

    deinit {
        stop()
        NotificationCenter.default.removeObserver(self)
    }

    func start() -> Bool {
        if globalUseBuiltInHyper {
            setupHidutil()
        }
        return setupEventTap()
    }

    // MARK: - hidutil (remap Caps Lock → F18 at system level)

    private func setupHidutil() {
        // Remap Caps Lock (0x39) to F18 (0x6D) using hidutil
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        task.arguments = [
            "property", "--set",
            "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":0x700000039,\"HIDKeyboardModifierMappingDst\":0x70000006D}]}"
        ]
        try? task.run()
        task.waitUntilExit()
    }

    private func clearHidutil() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        task.arguments = ["property", "--set", "{\"UserKeyMapping\":[]}"]
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: - CGEventTap (for hotkey interception)

    private func setupEventTap() -> Bool {
        // Event mask: keyDown + keyUp (for F18 hyper key detection)
        var eventMask = (1 << CGEventType.keyDown.rawValue)
        if globalUseBuiltInHyper {
            eventMask |= (1 << CGEventType.keyUp.rawValue)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: hotkeyEventCallback,
            userInfo: nil
        ) else {
            print("Failed to create event tap - accessibility permission required")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        return true
    }

    private func restartEventTap() {
        let savedHotkeys = hotkeys
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil

        _ = setupEventTap()
        hotkeys = savedHotkeys
        globalHotkeys = savedHotkeys
    }

    func stop() {
        if globalUseBuiltInHyper {
            clearHidutil()
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        globalHotkeys = []
        hyperKeyDown = false
        hyperKeyUsedAsModifier = false
    }

    func register(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, id: String) {
        let spec = HotkeySpec(keyCode: keyCode, modifiers: modifiers, id: id)
        hotkeys.append(spec)
        globalHotkeys.append(spec)
    }

    func clearHotkeys() {
        hotkeys.removeAll()
        globalHotkeys.removeAll()
    }

    @objc private func handleHotkeyNotification(_ notification: Notification) {
        guard let hotkeyId = notification.object as? String else { return }
        handler(hotkeyId)
    }
}

// MARK: - Event Tap Callback (C-compatible, no self reference)

private func hotkeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

    // Handle F18 (remapped from Caps Lock) as Hyper key
    if globalUseBuiltInHyper && keyCode == kF18KeyCode {
        let currentTime = mach_absolute_time()

        if type == .keyDown {
            hyperKeyDown = true
            hyperKeyUsedAsModifier = false
            hyperKeyPressTime = currentTime
            return nil
        }

        if type == .keyUp {
            hyperKeyDown = false
            let pressDuration = machTimeToNs(currentTime - hyperKeyPressTime)

            // Single tap (quick release without combining) = toggle Caps Lock
            if !hyperKeyUsedAsModifier && pressDuration < tapThresholdNs {
                capsLockEnabled.toggle()
                DispatchQueue.main.async {
                    setCapsLockState(capsLockEnabled)
                }
            }

            hyperKeyUsedAsModifier = false
            return nil
        }
    }

    // Handle key down for hotkeys
    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }

    let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))

    // Determine effective modifiers
    let relevantMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    var pressedMods = flags.intersection(relevantMask)

    // If Hyper key (F18) is held down, add all modifiers
    if globalUseBuiltInHyper && hyperKeyDown {
        hyperKeyUsedAsModifier = true
        pressedMods = [.command, .option, .control, .shift]
    }

    // Check against registered hotkeys
    for hotkey in globalHotkeys {
        if hotkey.keyCode == keyCode && hotkey.modifiers == pressedMods {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .hotkeyPressed,
                    object: hotkey.id
                )
            }
            return nil  // Consume the event
        }
    }

    return Unmanaged.passUnretained(event)
}

// MARK: - Helpers

private func machTimeToNs(_ machTime: UInt64) -> UInt64 {
    var timebaseInfo = mach_timebase_info_data_t()
    mach_timebase_info(&timebaseInfo)
    return machTime * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
}

private func setCapsLockState(_ on: Bool) {
    // Use IOKit to set Caps Lock LED/state
    var connect: io_connect_t = 0
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))

    guard service != 0 else { return }
    defer { IOObjectRelease(service) }

    guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return }
    defer { IOServiceClose(connect) }

    IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), on)
}
