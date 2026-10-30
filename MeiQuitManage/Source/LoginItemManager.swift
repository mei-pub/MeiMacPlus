import ServiceManagement

/// Launch-at-login via the modern `SMAppService` API (macOS 13+).
enum LoginItemManager {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// - Returns: `false` if the registration could not be changed (e.g. the
    ///   app is running outside a proper `.app` bundle).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("LoginItemManager: \(enabled ? "register" : "unregister") failed: \(error)")
            return false
        }
    }
}
