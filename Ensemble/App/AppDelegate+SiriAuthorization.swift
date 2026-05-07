#if os(iOS)
import Intents

extension AppDelegate {
    func configureSiriAuthorization() {
        let status = INPreferences.siriAuthorizationStatus()
        AppLogger.debug("AppDelegate: Siri authorization status at launch: \(status.rawValue)")

        guard status == .notDetermined else {
            return
        }

        INPreferences.requestSiriAuthorization { newStatus in
            AppLogger.debug("AppDelegate: Siri authorization prompt result: \(newStatus.rawValue)")
        }
    }
}
#endif
