// Window picker overlay: dims every display and badges each visible window
// with ⇪1…⇪0. Pressing the number focuses that window.

import AppKit

/// An on-screen window, as reported by the window server.
struct ScreenWindow {
    let pid: pid_t
    let frame: CGRect  // global, top-left origin
    let appName: String
}

enum WindowList {
    /// Normal app windows currently on screen, front-most first.
    /// Uses only window bounds and owners, so no Screen Recording permission is needed.
    static func onScreen() -> [ScreenWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let me = getpid()
        return info.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (d[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = d[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 80, frame.height >= 60,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular
            else { return nil }
            return ScreenWindow(pid: pid, frame: frame, appName: app.localizedName ?? "")
        }
    }

    /// Brings a window to the front and gives it keyboard focus.
    ///
    /// Recent macOS versions often ignore a background app asking for another app to
    /// become frontmost, so this escalates: Accessibility raise → app activation →
    /// Launch Services activation (what the Dock does), re-raising the window after.
    static func focus(_ w: ScreenWindow) {
        let app = AXUIElementCreateApplication(w.pid)
        let windows: [AXUIElement] = Windows.attribute(app, kAXWindowsAttribute) ?? []
        // Match the window server's window to the Accessibility one by frame.
        let match = windows.min { a, b in
            distance(Windows.frame(a), w.frame) < distance(Windows.frame(b), w.frame)
        }
        func raise() {
            guard let match else { return }
            AXUIElementSetAttributeValue(match, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(match, kAXRaiseAction as CFString)
        }

        raise()
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        let running = NSRunningApplication(processIdentifier: w.pid)
        if #available(macOS 14, *) { running?.activate() } else { running?.activate(options: []) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == w.pid { return }
            guard let url = running?.bundleURL else {
                NSLog("Snapback: couldn't focus \(w.appName): no bundle URL")
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                DispatchQueue.main.async {
                    raise()
                    let now = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                    NSLog("Snapback: focused \(w.appName) via Launch Services (error: \(error.map { "\($0)" } ?? "none")); frontmost is now \(now)")
                }
            }
        }
    }

    private static func distance(_ a: CGRect?, _ b: CGRect) -> CGFloat {
        guard let a else { return .infinity }
        return abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}

final class PickerOverlay {
    private var panels: [NSWindow] = []
    private var choices: [(choice: Picker.Choice, window: ScreenWindow)] = []

    var isVisible: Bool { !panels.isEmpty }

    /// Works out which windows get which numbers (without showing anything).
    private func computeChoices() {
        let windows = WindowList.onScreen()
        let displays = NSScreen.screens.compactMap(Self.cgFrame)
        choices = Picker.choices(frontToBack: windows.map(\.frame), displays: displays)
            .map { ($0, windows[$0.window]) }
    }

    func show() {
        hide()
        computeChoices()
        for screen in NSScreen.screens {
            guard let cg = Self.cgFrame(screen) else { continue }
            let panel = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            panel.setFrame(screen.frame, display: false)

            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.items = choices.compactMap { c in
                guard cg.contains(c.choice.badgeCenter) || cg.intersects(c.window.frame) else { return nil }
                return OverlayView.Item(frame: c.window.frame.offsetBy(dx: -cg.minX, dy: -cg.minY),
                                        badge: CGPoint(x: c.choice.badgeCenter.x - cg.minX, y: c.choice.badgeCenter.y - cg.minY),
                                        label: c.choice.label, appName: c.window.appName, z: c.choice.window)
            }
            panel.contentView = view
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
            panels.append(panel)
        }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    /// Focuses the window with the given label index (0 = "1"). Works even if the
    /// overlay isn't showing yet (Caps Lock + number pressed quickly).
    func pick(_ index: Int) {
        if choices.isEmpty || !isVisible { computeChoices() }
        hide()
        guard index < choices.count else { NSSound.beep(); return }
        WindowList.focus(choices[index].window)
    }

    /// A screen's frame in global top-left coordinates.
    private static func cgFrame(_ screen: NSScreen) -> CGRect? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        return CGDisplayBounds(id)
    }
}

final class OverlayView: NSView {
    struct Item {
        let frame: CGRect
        let badge: CGPoint
        let label: String
        let appName: String
        /// Stacking position: 0 is the front-most window.
        var z: Int = 0
    }

    var items: [Item] = []
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Desktop darker than the windows, so each window's shape stands out.
        let windowPaths = items.map { NSBezierPath(roundedRect: $0.frame, xRadius: 12, yRadius: 12) }
        let background = NSBezierPath(rect: bounds)
        windowPaths.forEach { background.append($0) }
        background.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.7).setFill()
        background.fill()

        let windowArea = NSBezierPath()
        windowPaths.forEach { windowArea.append($0) }
        windowArea.windingRule = .nonZero
        NSColor.black.withAlphaComponent(0.45).setFill()
        windowArea.fill()

        // Faint outlines, clipped so a window's edge isn't drawn across windows in front of it.
        for item in items {
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: bounds)
            for other in items where other.z < item.z {
                clip.append(NSBezierPath(roundedRect: other.frame, xRadius: 12, yRadius: 12))
            }
            clip.windingRule = .evenOdd
            clip.addClip()
            let outline = NSBezierPath(roundedRect: item.frame.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
            outline.lineWidth = 2
            NSColor.white.withAlphaComponent(0.35).setStroke()
            outline.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.65)
        shadow.shadowOffset = .zero

        for item in items {
            // Scale with the window, within readable limits.
            let size = min(max(min(item.frame.width, item.frame.height) * 0.6, 96), 280)
            shadow.shadowBlurRadius = size * 0.12

            let label = NSMutableAttributedString(string: "⇪", attributes: [
                .font: NSFont.systemFont(ofSize: size * 0.32, weight: .bold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.7),
                .baselineOffset: size * 0.36,
                .shadow: shadow,
            ])
            label.append(NSAttributedString(string: item.label, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .heavy),
                .foregroundColor: NSColor.white.withAlphaComponent(0.95),
                .shadow: shadow,
            ]))
            let ls = label.size()
            // Visually centre on the digit, not on the ⇪ + digit pair.
            let capsWidth = NSAttributedString(string: "⇪", attributes: [.font: NSFont.systemFont(ofSize: size * 0.32, weight: .bold)]).size().width
            let origin = NSPoint(x: item.badge.x - ls.width / 2 - capsWidth / 2, y: item.badge.y - ls.height / 2 - size * 0.08)
            label.draw(at: origin)

            let nameShadow = NSShadow()
            nameShadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
            nameShadow.shadowBlurRadius = 6
            let name = NSAttributedString(string: item.appName, attributes: [
                .font: NSFont.systemFont(ofSize: min(max(size * 0.12, 15), 28), weight: .semibold),
                .foregroundColor: NSColor.white,
                .shadow: nameShadow,
            ])
            let ns = name.size()
            name.draw(at: NSPoint(x: item.badge.x - ns.width / 2, y: origin.y + ls.height - size * 0.12))
        }
    }
}
