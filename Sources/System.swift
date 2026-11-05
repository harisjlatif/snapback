// Snapback: talking to macOS (displays, windows via Accessibility, global hotkeys).

import AppKit
import Carbon
import CoreGraphics

// MARK: - Displays

enum Displays {
    static func current() -> [Display] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.compactMap { id in
            // Skip displays that mirror another one.
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let str = CFUUIDCreateString(nil, uuid) as String?
            else { return nil }
            return Display(id: str, frame: CGDisplayBounds(id))
        }
    }
}

// MARK: - Windows

struct AppWindows {
    let app: NSRunningApplication
    let key: String
    let element: AXUIElement
    let windows: [AXUIElement]
}

enum Windows {
    static func appKey(_ app: NSRunningApplication) -> String? {
        app.bundleIdentifier ?? app.localizedName
    }

    /// Regular apps and their movable, visible, standard windows (front-most first).
    static func all() -> [AppWindows] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  app.processIdentifier != getpid(),
                  !app.isHidden,
                  let key = appKey(app)
            else { return nil }
            let el = AXUIElementCreateApplication(app.processIdentifier)
            let windows: [AXUIElement] = (attribute(el, kAXWindowsAttribute) as [AXUIElement]?) ?? []
            let usable = windows.filter(isUsable)
            return usable.isEmpty ? nil : AppWindows(app: app, key: key, element: el, windows: usable)
        }
    }

    static func isUsable(_ w: AXUIElement) -> Bool {
        let subrole: String? = attribute(w, kAXSubroleAttribute)
        let minimized: Bool = attribute(w, kAXMinimizedAttribute) ?? false
        let fullScreen: Bool = attribute(w, "AXFullScreen") ?? false
        guard subrole == kAXStandardWindowSubrole, !minimized, !fullScreen, let f = frame(w) else { return false }
        return f.width > 1 && f.height > 1
    }

    static func frame(_ w: AXUIElement) -> CGRect? {
        guard let posValue: AXValue = attribute(w, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(w, kAXSizeAttribute)
        else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    static func setFrame(_ w: AXUIElement, _ rect: CGRect) {
        var pos = rect.origin, size = rect.size
        guard let posValue = AXValueCreate(.cgPoint, &pos), let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        // Move, resize, then move again: some apps clamp the size to the display
        // the window is currently on, so the final move fixes up the position.
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, posValue)
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, posValue)
    }

    /// Runs `body` with the app's "enhanced user interface" mode turned off.
    /// Some apps (e.g. Chrome with VoiceOver features on) animate or ignore
    /// window moves while it's enabled.
    static func withoutEnhancedUI(_ app: AXUIElement, _ body: () -> Void) {
        let attr = "AXEnhancedUserInterface" as CFString
        let enabled: Bool = attribute(app, attr as String) ?? false
        if enabled { AXUIElementSetAttributeValue(app, attr, kCFBooleanFalse) }
        body()
        if enabled { AXUIElementSetAttributeValue(app, attr, kCFBooleanTrue) }
    }

    static func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

// MARK: - Global hotkeys (Carbon; needs no extra permission)

enum HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false

    static func register(id: UInt32, keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) {
        installIfNeeded()
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E_4150), id: id)  // "SNAP"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) } else { NSLog("Snapback: hotkey \(id) failed (\(status))") }
    }

    private static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotKeys.handlers[hk.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - Caps Lock → F18 (HID-level remap; no permission needed)

enum CapsLockRemap {
    private static let capsLock = "0x700000039"
    private static let f18 = "0x70000006D"

    /// Remaps Caps Lock to F18 for all keyboards. Lasts until reboot or `disable()`.
    static func enable() {
        hidutil(#"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":\#(capsLock),"HIDKeyboardModifierMappingDst":\#(f18)}]}"#)
    }

    static func disable() {
        hidutil(#"{"UserKeyMapping":[]}"#)
    }

    private static func hidutil(_ json: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = ["property", "--set", json]
        p.standardOutput = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { NSLog("Snapback: hidutil failed: \(error)") }
    }
}

// MARK: - Keyboard event tap (needs Accessibility)

/// Applies the Hyper key to keyboard events. `onHyperKeyDown` is offered each
/// Hyper+key press first; returning true consumes it (used for Snapback's own shortcuts).
final class KeyTap {
    static let shared = KeyTap()

    let hyper = HyperKey()
    var enabled = true
    var onHyperKeyDown: ((UInt16) -> Bool)?
    /// Called when Caps Lock goes down (not on auto-repeat) and when it's released.
    var onTriggerDown: (() -> Void)?
    var onTriggerUp: (() -> Void)?

    private var port: CFMachPort?
    private var consumedKeys = Set<UInt16>()
    private static let marker: Int64 = 0x534E_4150  // "SNAP": events we post ourselves

    /// Starts the tap. Returns false if Accessibility access is missing.
    @discardableResult
    func start() -> Bool {
        if port != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: { proxy, type, event, _ in
                                               KeyTap.shared.handle(proxy: proxy, type: type, event: event)
                                           }, userInfo: nil)
        else { return false }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard enabled, event.getIntegerValueField(.eventSourceUserData) != Self.marker else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isDown = type == .keyDown

        let wasHeld = hyper.isHeld
        let result = hyper.handle(keyCode: keyCode, isDown: isDown, time: ProcessInfo.processInfo.systemUptime)
        if keyCode == HyperKey.triggerKeyCode {
            if isDown, !wasHeld { onTriggerDown?() }
            if !isDown { onTriggerUp?() }
        }

        // Key-up of a shortcut we handled ourselves.
        if !isDown, consumedKeys.remove(keyCode) != nil { return nil }

        switch result {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .hyper:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if isDown, !isRepeat, onHyperKeyDown?(keyCode) == true {
                consumedKeys.insert(keyCode)
                return nil
            }
            if consumedKeys.contains(keyCode) { return nil }  // auto-repeat of a handled shortcut
            event.flags = CGEventFlags(rawValue: event.flags.rawValue | HyperKey.hyperFlags)
            return Unmanaged.passUnretained(event)
        case .escape:
            for down in [true, false] {
                if let e = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down) {
                    e.flags = []
                    e.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                    e.tapPostEvent(proxy)
                }
            }
            return nil
        }
    }
}
