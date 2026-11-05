// Snapback: save your window layout, snap back to it with a hotkey.
//
//   ⌃⌥⌘S or Hyper+S  save the current layout for this display setup
//   ⌃⌥⌘R or Hyper+R  restore it
//
// Hyper = hold Caps Lock (acts as ⌃⌥⇧⌘). Tapping Caps Lock alone types Escape.

import AppKit
import Carbon

final class Snapback: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var store = Store()
    private let storeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snapback", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("layouts.json")
    }()

    private enum Pref {
        static let hyperKey = "hyperKeyEnabled"
        static let tapEscape = "capsLockTapEscape"
    }
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        load()
        defaults.register(defaults: [Pref.hyperKey: true, Pref.tapEscape: true])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Snapback")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let mods = cmdKey | optionKey | controlKey
        HotKeys.register(id: 1, keyCode: kVK_ANSI_S, modifiers: mods) { [weak self] in self?.save() }
        HotKeys.register(id: 2, keyCode: kVK_ANSI_R, modifiers: mods) { [weak self] in self?.restore() }

        KeyTap.shared.onHyperKeyDown = { [weak self] keyCode in
            switch Int(keyCode) {
            case kVK_ANSI_S: DispatchQueue.main.async { self?.save() }; return true
            case kVK_ANSI_R: DispatchQueue.main.async { self?.restore() }; return true
            default: return false
            }
        }
        applyHyperSettings()
        // Remaps are cleared on sleep/wake on some Macs; re-apply.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in self?.applyHyperSettings() }

        // Let the menu bar icon appear before any dialog.
        DispatchQueue.main.async { [weak self] in self?.requestPermissionIfNeeded() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        CapsLockRemap.disable()  // give Caps Lock back
    }

    // MARK: Hyper key

    /// Turns the Caps Lock remap and key tap on or off to match the settings.
    /// Caps Lock is only remapped once the tap is running, so it never becomes a dead key.
    private func applyHyperSettings() {
        let tap = KeyTap.shared
        tap.hyper.tapForEscape = defaults.bool(forKey: Pref.tapEscape)
        if defaults.bool(forKey: Pref.hyperKey), tap.start() {
            tap.enabled = true
            CapsLockRemap.enable()
        } else {
            tap.enabled = false
            CapsLockRemap.disable()
        }
    }

    @objc private func toggleHyperKey() {
        defaults.set(!defaults.bool(forKey: Pref.hyperKey), forKey: Pref.hyperKey)
        applyHyperSettings()
    }

    @objc private func toggleTapEscape() {
        defaults.set(!defaults.bool(forKey: Pref.tapEscape), forKey: Pref.tapEscape)
        applyHyperSettings()
    }

    // MARK: Accessibility permission

    private var permissionTimer: Timer?
    private var permissionAlertOpen = false

    /// Explains why Accessibility access is needed and offers to open System Settings.
    /// Watches for the permission being granted and confirms when it is.
    @objc private func requestPermissionIfNeeded() {
        guard !AXIsProcessTrusted(), !permissionAlertOpen else { return }
        watchForPermission()

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
        alert.messageText = "Snapback needs Accessibility access"
        alert.informativeText = """
            Snapback moves and resizes other apps' windows, which macOS only allows \
            for apps you've given Accessibility access.

            Click Open System Settings, then turn on Snapback. \
            Snapback will notice as soon as it's enabled; there's no need to restart it.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")

        permissionAlertOpen = true
        let response = alert.runModal()
        permissionAlertOpen = false

        if response == .alertFirstButtonReturn {
            // Adds Snapback to the Accessibility list so the user only has to flip the switch.
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            openAccessibility()
        }
    }

    private func watchForPermission() {
        guard permissionTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted(), let self else { return }
            timer.invalidate()
            self.permissionTimer = nil
            if self.permissionAlertOpen { NSApp.abortModal() }
            self.applyHyperSettings()
            DispatchQueue.main.async { self.showReady() }
        }
        // .common so it keeps firing while a dialog is open.
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func showReady() {
        NSSound(named: "Glass")?.play()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        alert.messageText = "Snapback is ready"
        alert.informativeText = """
            Arrange your windows, then press Caps Lock + S (or ⌃⌥⌘S) to save the layout.
            Press Caps Lock + R (or ⌃⌥⌘R) any time to snap back to it.

            Caps Lock is now a Hyper key: hold it with any key for ⌃⌥⇧⌘, \
            or tap it on its own for Escape. You can turn this off in the Snapback menu.
            """
        alert.addButton(withTitle: "Got It")
        alert.runModal()
    }

    // MARK: Menu (rebuilt each time it opens so the status line is current)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let save = menu.addItem(withTitle: "Save Layout", action: #selector(saveAction), keyEquivalent: "s")
        save.keyEquivalentModifierMask = [.control, .option, .command]
        let restore = menu.addItem(withTitle: "Restore Layout", action: #selector(restoreAction), keyEquivalent: "r")
        restore.keyEquivalentModifierMask = [.control, .option, .command]
        menu.addItem(.separator())

        let displays = Displays.current()
        let info: String
        if let layout = store.layouts[Geometry.setupKey(displays)] {
            let when = DateFormatter.localizedString(from: layout.savedAt, dateStyle: .short, timeStyle: .short)
            info = "\(layout.apps.count) apps saved for \(displays.count) display\(displays.count == 1 ? "" : "s") · \(when)"
        } else {
            info = "No layout saved for this display setup"
        }
        menu.addItem(withTitle: info, action: nil, keyEquivalent: "").isEnabled = false

        if !AXIsProcessTrusted() {
            menu.addItem(withTitle: "Grant Accessibility Access…", action: #selector(requestPermissionIfNeeded), keyEquivalent: "")
        }
        menu.addItem(.separator())

        let hyperOn = defaults.bool(forKey: Pref.hyperKey)
        menu.addItem(withTitle: "Caps Lock as Hyper Key (⌃⌥⇧⌘)", action: #selector(toggleHyperKey), keyEquivalent: "")
            .state = hyperOn ? .on : .off
        let escape = menu.addItem(withTitle: "Tap Caps Lock for Escape",
                                  action: hyperOn ? #selector(toggleTapEscape) : nil, keyEquivalent: "")
        escape.state = defaults.bool(forKey: Pref.tapEscape) ? .on : .off
        escape.indentationLevel = 1
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Snapback", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
    }

    @objc private func saveAction() { save() }
    @objc private func restoreAction() { restore() }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: Save / restore

    private func save() {
        guard ensureTrusted() else { return }
        let displays = Displays.current()
        var apps: [String: [SavedFrame]] = [:]
        for app in Windows.all() {
            let frames = app.windows.compactMap(Windows.frame).compactMap { Geometry.save($0, displays: displays) }
            if !frames.isEmpty { apps[app.key] = frames }
        }
        store.layouts[Geometry.setupKey(displays)] = Layout(savedAt: Date(), apps: apps)
        persist()
        feedback(success: true, sound: "Tink")
        NSLog("Snapback: saved \(apps.count) apps across \(displays.count) displays")
    }

    private func restore() {
        guard ensureTrusted() else { return }
        let displays = Displays.current()
        guard let layout = store.layouts[Geometry.setupKey(displays)] else {
            feedback(success: false, sound: "Basso")
            NSLog("Snapback: no layout saved for this display setup")
            return
        }
        var moved = 0
        for app in Windows.all() {
            guard let saved = layout.apps[app.key] else { continue }
            let targets = saved.compactMap { Geometry.restore($0, displays: displays) }
            let current = app.windows.map { Windows.frame($0) ?? .zero }
            let assignment = Geometry.assign(current: current, targets: targets)
            Windows.withoutEnhancedUI(app.element) {
                for (window, target) in zip(app.windows, assignment) {
                    Windows.setFrame(window, targets[target])
                    moved += 1
                }
            }
        }
        feedback(success: true, sound: "Pop")
        NSLog("Snapback: restored \(moved) windows")
    }

    private func ensureTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        feedback(success: false, sound: "Basso")
        // Async: this can be called from inside a hotkey event handler.
        DispatchQueue.main.async { [weak self] in self?.requestPermissionIfNeeded() }
        return false
    }

    /// Plays a sound and briefly swaps the menu bar icon to a check or cross.
    private func feedback(success: Bool, sound: String) {
        NSSound(named: sound)?.play()
        let original = statusItem.button?.image
        statusItem.button?.image = NSImage(systemSymbolName: success ? "checkmark.circle" : "xmark.circle",
                                           accessibilityDescription: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.statusItem.button?.image = original }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { store = try decoder.decode(Store.self, from: data) }
        catch { NSLog("Snapback: couldn't read \(storeURL.path): \(error)") }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do { try encoder.encode(store).write(to: storeURL, options: .atomic) }
        catch { NSLog("Snapback: couldn't save \(storeURL.path): \(error)") }
    }
}

// launchd stops us with SIGTERM (uninstall, logout, restart), which skips
// applicationWillTerminate, so give Caps Lock back here too.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler {
    CapsLockRemap.disable()
    exit(0)
}
sigterm.resume()

let app = NSApplication.shared
let delegate = Snapback()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
