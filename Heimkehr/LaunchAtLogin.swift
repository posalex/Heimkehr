import Foundation
import ServiceManagement

/// Dünner Wrapper um `SMAppService.mainApp`.
///
/// Erfordert macOS 13. Ein LaunchAgent-Plist ist nicht mehr nötig — die API
/// kümmert sich um die Registrierung anhand der App-Bundle-Identität.
enum LaunchAtLogin {

    /// `true` wenn Heimkehr als Anmeldeobjekt registriert und aktiv ist.
    static var isEnabled: Bool {
        return SMAppService.mainApp.status == .enabled
    }

    /// Aktiviert oder deaktiviert den Autostart.
    /// - Returns: `true` bei Erfolg, `false` wenn das System die Änderung
    ///   ablehnt (z.B. weil der User es in den Systemeinstellungen
    ///   verboten hat — dann erscheint dort ein entsprechender Schalter).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
            return true
        } catch {
            NSLog("Heimkehr: LaunchAtLogin.setEnabled(%@) fehlgeschlagen: %@",
                  enabled ? "true" : "false",
                  error.localizedDescription)
            return false
        }
    }
}
