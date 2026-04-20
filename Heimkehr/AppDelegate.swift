import Cocoa
import SwiftUI
import Carbon.HIToolbox

/// Debug-Logging: im Release-Build ein No-op.
/// `print` landet in Xcodes Debug Area, `NSLog` in Console.app.
@inline(__always)
fileprivate func hkLog(_ message: String) {
#if DEBUG
    print("Heimkehr: \(message)")
    NSLog("Heimkehr: %@", message)
#endif
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var windowManager: WindowManager!

    // Carbon-Hotkey-Registry: ID → (Ref, Aktion)
    //
    // Static, weil `@NSApplicationDelegateAdaptor` in SwiftUI unter bestimmten
    // Bedingungen ZWEI AppDelegate-Instanzen anlegt: eine bekommt die
    // Delegate-Callbacks (dort läuft applicationDidFinishLaunching und damit
    // die Hotkey-Registrierung), die andere wird zu `NSApp.delegate`. Eine
    // Instanz-Property würde dann beim Carbon-Callback leer erscheinen.
    fileprivate static var hotKeyHandlers: [UInt32: () -> Void] = [:]
    private static var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private static var hotKeyHandlerInstalled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        hkLog("applicationDidFinishLaunching START")

        // Als Menüleisten-App (ohne Dock-Icon) starten
        NSApp.setActivationPolicy(.accessory)

        windowManager = WindowManager()

        setupStatusItem()
        registerGlobalHotkeys()

        // Beim Start prüfen, ob Accessibility-Rechte vorhanden sind
        checkAccessibilityPermissions()

        // Neu aufbauen wenn sich Bildschirm-Konfiguration ändert
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "house.fill",
                accessibilityDescription: "Heimkehr"
            )
        }
        rebuildMenu()
    }

    @objc func screenParametersChanged() {
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        // Wir verwalten den Enable-Zustand selbst (sonst überschreibt
        // AppKit `restoreItem.isEnabled`, weil der Selector gültig ist).
        menu.autoenablesItems = false

        // Haupt-Aktion
        let homeItem = NSMenuItem(
            title: NSLocalizedString("menu_move_internal", comment: ""),
            action: #selector(moveAllToInternal),
            keyEquivalent: "h"
        )
        homeItem.keyEquivalentModifierMask = [.control, .option, .command]
        homeItem.target = self
        menu.addItem(homeItem)

        let nextItem = NSMenuItem(
            title: NSLocalizedString("menu_move_next", comment: ""),
            action: #selector(moveAllToNext),
            keyEquivalent: ""
        )
        nextItem.target = self
        menu.addItem(nextItem)

        menu.addItem(NSMenuItem.separator())

        // Pro Monitor ein Eintrag
        let screens = NSScreen.screens
        let internalID = WindowManager.internalScreenID()
        let internalSuffix = NSLocalizedString("menu_monitor_internal_suffix", comment: "")
        let monitorFormat = NSLocalizedString("menu_move_to_monitor_format", comment: "")

        for (index, screen) in screens.enumerated() {
            let isInternal = (screen.displayID == internalID)
            let label = screen.localizedName
            let baseTitle = String(format: monitorFormat, index + 1, label)
            let title = baseTitle + (isInternal ? internalSuffix : "")

            let item = NSMenuItem(
                title: title,
                action: #selector(moveAllToSpecificScreen(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let restoreItem = NSMenuItem(
            title: NSLocalizedString("menu_restore", comment: ""),
            action: #selector(restoreSnapshot),
            keyEquivalent: "z"
        )
        restoreItem.keyEquivalentModifierMask = [.control, .option, .command]
        restoreItem.target = self
        restoreItem.isEnabled = windowManager.hasSnapshot
        menu.addItem(restoreItem)

        menu.addItem(NSMenuItem.separator())

        let permItem = NSMenuItem(
            title: NSLocalizedString("menu_open_accessibility", comment: ""),
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        permItem.target = self
        menu.addItem(permItem)

        let loginItem = NSMenuItem(
            title: NSLocalizedString("menu_launch_at_login", comment: ""),
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(loginItem)

        let aboutItem = NSMenuItem(
            title: NSLocalizedString("menu_about", comment: ""),
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: NSLocalizedString("menu_quit", comment: ""),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Aktionen

    @objc func moveAllToInternal() {
        guard ensureAccessibility() else { return }
        windowManager.moveAllWindowsToInternalDisplay()
        rebuildMenu()
    }

    @objc func moveAllToNext() {
        guard ensureAccessibility() else { return }
        windowManager.moveAllWindowsToNextDisplay()
        rebuildMenu()
    }

    @objc func moveAllToSpecificScreen(_ sender: NSMenuItem) {
        guard ensureAccessibility() else { return }
        let index = sender.tag
        let screens = NSScreen.screens
        guard index >= 0 && index < screens.count else { return }
        windowManager.moveAllWindows(to: screens[index])
        rebuildMenu()
    }

    @objc func restoreSnapshot() {
        guard ensureAccessibility() else { return }
        windowManager.restoreSnapshot()
        rebuildMenu()
    }

    @objc func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc func toggleLaunchAtLogin() {
        let newState = !LaunchAtLogin.isEnabled
        if !LaunchAtLogin.setEnabled(newState) {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString(
                "launch_at_login_failed_title",
                comment: "Alert title when toggling Launch at Login fails")
            alert.informativeText = NSLocalizedString(
                "launch_at_login_failed_body",
                comment: "Alert body when toggling Launch at Login fails")
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("ok", comment: "OK button"))
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("about_title", comment: "")
        alert.informativeText = NSLocalizedString("about_body", comment: "")
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("ok", comment: ""))
        alert.runModal()
    }

    // MARK: - Berechtigungen

    func checkAccessibilityPermissions() {
        if !AXIsProcessTrusted() {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("accessibility_required_title", comment: "")
            alert.informativeText = NSLocalizedString("accessibility_required_body", comment: "")
            alert.addButton(withTitle: NSLocalizedString("button_open_settings", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("button_later", comment: ""))
            if alert.runModal() == .alertFirstButtonReturn {
                openAccessibilitySettings()
            }
        }
    }

    func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        checkAccessibilityPermissions()
        return false
    }

    // MARK: - Globale Hotkeys (Carbon)

    /// Registriert alle globalen Hotkeys. Wird einmal beim App-Start aufgerufen.
    func registerGlobalHotkeys() {
        hkLog("registerGlobalHotkeys() aufgerufen")
        installHotKeyEventHandlerIfNeeded()

        let modifiers = UInt32(cmdKey | optionKey | controlKey)

        // ⌃⌥⌘H — alle Fenster zum internen Display
        registerHotKey(id: 1,
                       keyCode: UInt32(kVK_ANSI_H),
                       modifiers: modifiers) { [weak self] in
            self?.moveAllToInternal()
        }

        // ⌃⌥⌘Z — ursprüngliche Positionen wiederherstellen
        registerHotKey(id: 2,
                       keyCode: UInt32(kVK_ANSI_Z),
                       modifiers: modifiers) { [weak self] in
            self?.restoreSnapshot()
        }
    }

    /// Installiert den Carbon-Event-Handler genau einmal pro Prozess.
    /// Der Callback darf kein `self` capturen (C-Calling-Convention),
    /// deshalb greift er auf die statische Handler-Map zu.
    private func installHotKeyEventHandlerIfNeeded() {
        guard !AppDelegate.hotKeyHandlerInstalled else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                hkLog("Carbon-Callback gefeuert")
                guard let event = event else { return noErr }
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID)
                guard err == noErr else {
                    hkLog("GetEventParameter fehlgeschlagen (OSStatus=\(err))")
                    return err
                }
                hkLog("Hotkey-ID=\(hkID.id) empfangen (Map-Size=\(AppDelegate.hotKeyHandlers.count))")

                let handler = AppDelegate.hotKeyHandlers[hkID.id]
                DispatchQueue.main.async {
                    if let handler = handler {
                        hkLog("Handler für ID=\(hkID.id) wird ausgeführt")
                        handler()
                    } else {
                        hkLog("KEIN Handler für ID=\(hkID.id) gefunden")
                    }
                }
                return noErr
            },
            1, &eventType, nil, nil)

        hkLog("InstallEventHandler OSStatus=\(status)")
        if status == noErr {
            AppDelegate.hotKeyHandlerInstalled = true
        }
    }

    /// Registriert einen einzelnen Hotkey und merkt sich den Handler.
    private func registerHotKey(id: UInt32,
                                keyCode: UInt32,
                                modifiers: UInt32,
                                handler: @escaping () -> Void) {
        let hotKeyID = EventHotKeyID(signature: OSType(0x484B4852), id: id) // 'HKHR'
        var ref: EventHotKeyRef?

        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref)

        hkLog("RegisterEventHotKey id=\(id) keyCode=\(keyCode) OSStatus=\(status)")

        if status == noErr, let ref = ref {
            AppDelegate.hotKeyHandlers[id] = handler
            AppDelegate.hotKeyRefs[id] = ref
        } else {
            hkLog("RegisterEventHotKey fehlgeschlagen (id=\(id), OSStatus=\(status)). " +
                  "Vermutlich ist das Kürzel bereits von einer anderen App belegt.")
        }
    }
}

// Komfort-Extension: Display-ID aus NSScreen holen
extension NSScreen {
    var displayID: CGDirectDisplayID {
        return deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}
