#if os(iOS)
import Intents

extension AppDelegate {
    func configureSiriAuthorization() {
        #if targetEnvironment(simulator)
        AppLogger.debug("AppDelegate: Siri authorization skipped on simulator")
        return
        #else
        let status = INPreferences.siriAuthorizationStatus()
        AppLogger.debug("AppDelegate: Siri authorization status at launch: \(status.rawValue)")

        guard status == .notDetermined else {
            return
        }

        INPreferences.requestSiriAuthorization { newStatus in
            AppLogger.debug("AppDelegate: Siri authorization prompt result: \(newStatus.rawValue)")
        }
        #endif
    }
}
#endif
