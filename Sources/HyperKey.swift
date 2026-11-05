// Hyper key state machine (pure logic, unit tested).
//
// Caps Lock is remapped to F18 at the HID level (see CapsLockRemap), and this
// decides what each key event becomes:
//
//   * F18 held + another key  → that key with ⌃⌥⇧⌘ added ("Hyper")
//   * F18 tapped on its own   → Escape (if enabled and released quickly)
//   * everything else         → unchanged

import Foundation

public final class HyperKey {
    public static let triggerKeyCode: UInt16 = 79  // kVK_F18
    /// CGEventFlags for ⌃⌥⇧⌘.
    public static let hyperFlags: UInt64 = 0x0004_0000 | 0x0008_0000 | 0x0002_0000 | 0x0010_0000

    public enum Result: Equatable {
        /// Let the event through unchanged.
        case pass
        /// Drop the event.
        case swallow
        /// Let the event through with Hyper modifiers added.
        case hyper
        /// Drop the event and type Escape instead.
        case escape
    }

    /// Taps on their own longer than this don't produce Escape (you were probably
    /// holding Caps Lock and changed your mind).
    public var tapTimeout: TimeInterval
    public var tapForEscape: Bool

    public private(set) var isHeld = false
    private var usedAsModifier = false
    private var pressedAt: TimeInterval = 0
    /// Keys whose key-down got Hyper, so their key-up gets it too.
    private var hyperKeysDown = Set<UInt16>()

    public init(tapForEscape: Bool = true, tapTimeout: TimeInterval = 0.5) {
        self.tapForEscape = tapForEscape
        self.tapTimeout = tapTimeout
    }

    public func handle(keyCode: UInt16, isDown: Bool, time: TimeInterval) -> Result {
        if keyCode == Self.triggerKeyCode {
            if isDown {
                if !isHeld {  // ignore auto-repeat
                    isHeld = true
                    usedAsModifier = false
                    pressedAt = time
                }
                return .swallow
            }
            isHeld = false
            let wasTap = !usedAsModifier && time - pressedAt <= tapTimeout
            return wasTap && tapForEscape ? .escape : .swallow
        }

        if isDown, isHeld {
            usedAsModifier = true
            hyperKeysDown.insert(keyCode)
            return .hyper
        }
        if !isDown, hyperKeysDown.remove(keyCode) != nil {
            return .hyper
        }
        return .pass
    }
}
