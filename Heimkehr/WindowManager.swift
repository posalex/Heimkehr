import Cocoa
import ApplicationServices

/// Ein Schnappschuss einer Fensterposition – für die Wiederherstellung.
struct WindowSnapshot {
    let pid: pid_t
    let windowIndex: Int     // Index des Fensters innerhalb der App
    let appName: String
    let title: String
    let frame: CGRect
}

class WindowManager {
    private var lastSnapshot: [WindowSnapshot] = []

    var hasSnapshot: Bool { !lastSnapshot.isEmpty }

    // MARK: - Öffentliche API

    /// Bewegt alle Fenster aller Apps auf das interne Display.
    func moveAllWindowsToInternalDisplay() {
        guard let screen = internalScreen() else {
            NSSound.beep()
            return
        }
        moveAllWindows(to: screen)
    }

    /// Bewegt alle Fenster zyklisch auf das nächste Display.
    /// „Nächstes“ bezieht sich auf das Display rechts vom Haupt-Schwerpunkt der Fenster.
    func moveAllWindowsToNextDisplay() {
        let screens = NSScreen.screens
        guard screens.count > 1 else {
            NSSound.beep()
            return
        }

        // Aktuell dominierendes Display anhand aller Fenster bestimmen
        let windows = collectAllWindows()
        let currentScreen = dominantScreen(for: windows) ?? screens[0]
        let currentIndex = screens.firstIndex(where: { $0.displayID == currentScreen.displayID }) ?? 0
        let nextIndex = (currentIndex + 1) % screens.count
        moveAllWindows(to: screens[nextIndex])
    }

    /// Bewegt alle Fenster auf den angegebenen Bildschirm.
    func moveAllWindows(to targetScreen: NSScreen) {
        // Snapshot NUR beim ersten Move nach einem Restore anlegen.
        // Sonst überschreibt jedes weitere Verschieben den ursprünglichen
        // Zustand, und „Wiederherstellen“ würde nur einen Schritt zurückgehen
        // statt zur echten Ausgangs-Konfiguration.
        if lastSnapshot.isEmpty {
            saveSnapshot()
        }

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        for app in apps {
            moveWindows(of: app, to: targetScreen)
        }
    }

    /// Stellt die zuletzt gespeicherten Fensterpositionen wieder her.
    func restoreSnapshot() {
        guard !lastSnapshot.isEmpty else {
            NSSound.beep()
            return
        }

        // Nach PID gruppieren, für jede App die Fenster durchgehen
        let byPid = Dictionary(grouping: lastSnapshot, by: { $0.pid })

        for (pid, snaps) in byPid {
            let appElement = AXUIElementCreateApplication(pid)
            guard let windows = getWindows(of: appElement) else { continue }

            // Snapshots nach windowIndex sortieren und passend zuordnen
            let sorted = snaps.sorted { $0.windowIndex < $1.windowIndex }
            for snap in sorted {
                guard snap.windowIndex < windows.count else { continue }
                let window = windows[snap.windowIndex]
                setFrame(snap.frame, for: window)
            }
        }

        lastSnapshot.removeAll()
    }

    // MARK: - Snapshot

    private func saveSnapshot() {
        lastSnapshot.removeAll()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        for app in apps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows = getWindows(of: appElement) else { continue }

            for (idx, window) in windows.enumerated() {
                guard let frame = getFrame(for: window) else { continue }
                let title = getTitle(for: window) ?? ""
                lastSnapshot.append(WindowSnapshot(
                    pid: app.processIdentifier,
                    windowIndex: idx,
                    appName: app.localizedName ?? "",
                    title: title,
                    frame: frame
                ))
            }
        }
    }

    // MARK: - Fenster sammeln / verschieben

    private struct WindowRef {
        let element: AXUIElement
        let frame: CGRect
    }

    private func collectAllWindows() -> [WindowRef] {
        var result: [WindowRef] = []
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }
        for app in apps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows = getWindows(of: appElement) else { continue }
            for w in windows {
                if let f = getFrame(for: w) {
                    result.append(WindowRef(element: w, frame: f))
                }
            }
        }
        return result
    }

    private func moveWindows(of app: NSRunningApplication, to targetScreen: NSScreen) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = getWindows(of: appElement) else { return }

        let targetFrame = screenFrameInAXCoordinates(targetScreen)

        for window in windows {
            guard let currentFrame = getFrame(for: window) else { continue }

            // Aktuellen Screen bestimmen (über Mittelpunkt)
            let center = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
            let currentScreen = screenContaining(axPoint: center)

            // Falls das Fenster schon auf dem Ziel-Screen ist: überspringen
            if currentScreen?.displayID == targetScreen.displayID {
                continue
            }

            // Neue Position berechnen: relative Position im Quell-Screen beibehalten
            var newOrigin: CGPoint
            var newSize = currentFrame.size

            // Falls Fenster größer als Zieldisplay ist: passend verkleinern
            if newSize.width > targetFrame.width {
                newSize.width = targetFrame.width
            }
            if newSize.height > targetFrame.height {
                newSize.height = targetFrame.height
            }

            if let src = currentScreen {
                let srcFrame = screenFrameInAXCoordinates(src)
                let relX = (currentFrame.origin.x - srcFrame.origin.x) / max(srcFrame.width, 1)
                let relY = (currentFrame.origin.y - srcFrame.origin.y) / max(srcFrame.height, 1)
                newOrigin = CGPoint(
                    x: targetFrame.origin.x + relX * targetFrame.width,
                    y: targetFrame.origin.y + relY * targetFrame.height
                )
            } else {
                // Kein Quell-Screen gefunden (Fenster „offscreen“) → in linke obere Ecke
                newOrigin = CGPoint(x: targetFrame.origin.x + 40, y: targetFrame.origin.y + 40)
            }

            // Clipping: Fenster vollständig auf Zielbildschirm halten
            if newOrigin.x + newSize.width > targetFrame.maxX {
                newOrigin.x = targetFrame.maxX - newSize.width
            }
            if newOrigin.y + newSize.height > targetFrame.maxY {
                newOrigin.y = targetFrame.maxY - newSize.height
            }
            newOrigin.x = max(newOrigin.x, targetFrame.origin.x)
            newOrigin.y = max(newOrigin.y, targetFrame.origin.y)

            setFrame(CGRect(origin: newOrigin, size: newSize), for: window)
        }
    }

    // MARK: - AX Helpers

    private func getWindows(of appElement: AXUIElement) -> [AXUIElement]? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &value
        )
        guard result == .success, let windows = value as? [AXUIElement] else {
            return nil
        }
        return windows
    }

    private func getFrame(for window: AXUIElement) -> CGRect? {
        guard let pos = getPoint(window, attribute: kAXPositionAttribute),
              let size = getSize(window, attribute: kAXSizeAttribute) else {
            return nil
        }
        return CGRect(origin: pos, size: size)
    }

    private func getPoint(_ element: AXUIElement, attribute: String) -> CGPoint? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        var point = CGPoint.zero
        if let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() {
            AXValueGetValue(axValue as! AXValue, .cgPoint, &point)
            return point
        }
        return nil
    }

    private func getSize(_ element: AXUIElement, attribute: String) -> CGSize? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        var size = CGSize.zero
        if let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() {
            AXValueGetValue(axValue as! AXValue, .cgSize, &size)
            return size
        }
        return nil
    }

    private func getTitle(for window: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func setFrame(_ frame: CGRect, for window: AXUIElement) {
        var position = frame.origin
        var size = frame.size

        // Reihenfolge: erst Position, dann Größe, dann nochmal Position
        // (macht manchen Apps wie Chrome/Electron weniger Probleme)
        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        }
    }

    // MARK: - Screen-Hilfsfunktionen

    /// AX-Koordinaten haben ihren Ursprung oben links auf dem Haupt-Display.
    /// NSScreen.frame hat den Ursprung unten links. Wir rechnen um.
    private func screenFrameInAXCoordinates(_ screen: NSScreen) -> CGRect {
        guard let main = NSScreen.screens.first else { return screen.frame }
        let mainHeight = main.frame.height
        let f = screen.frame
        // y-Flip: AX-y = mainHeight - (NSScreen-y + height)
        let axY = mainHeight - (f.origin.y + f.height)
        return CGRect(x: f.origin.x, y: axY, width: f.width, height: f.height)
    }

    private func screenContaining(axPoint point: CGPoint) -> NSScreen? {
        for screen in NSScreen.screens {
            let axFrame = screenFrameInAXCoordinates(screen)
            if axFrame.contains(point) {
                return screen
            }
        }
        return nil
    }

    private func dominantScreen(for windows: [WindowRef]) -> NSScreen? {
        var counts: [CGDirectDisplayID: Int] = [:]
        for w in windows {
            let center = CGPoint(x: w.frame.midX, y: w.frame.midY)
            if let s = screenContaining(axPoint: center) {
                counts[s.displayID, default: 0] += 1
            }
        }
        guard let (id, _) = counts.max(by: { $0.value < $1.value }) else { return nil }
        return NSScreen.screens.first(where: { $0.displayID == id })
    }

    // MARK: - Internes Display erkennen

    private func internalScreen() -> NSScreen? {
        let id = WindowManager.internalScreenID()
        return NSScreen.screens.first(where: { $0.displayID == id })
    }

    static func internalScreenID() -> CGDirectDisplayID {
        // CGDisplayIsBuiltin sagt uns, ob ein Display im Gehäuse verbaut ist
        for screen in NSScreen.screens {
            let id = screen.displayID
            if CGDisplayIsBuiltin(id) != 0 {
                return id
            }
        }
        // Fallback: Haupt-Display
        return NSScreen.main?.displayID ?? CGMainDisplayID()
    }
}
