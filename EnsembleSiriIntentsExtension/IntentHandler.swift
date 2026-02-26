import Intents
import os

open class IntentHandler: INExtension {
    private let logger = Logger(subsystem: "com.videogorl.ensemble.siri-intents", category: "IntentHandler")

    public override init() {
        super.init()
        // Log immediately after super.init to confirm the class is instantiated
        logger.info("IntentHandler.init() called - extension is loading")
        os_log(.info, "SIRI_EXT: IntentHandler.init() called")
    }

    public override func handler(for intent: INIntent) -> Any {
        logger.info("handler(for:): intent=\(String(describing: type(of: intent)), privacy: .public)")
        os_log(.info, "SIRI_EXT: handler(for:) called with intent type: %{public}@", String(describing: type(of: intent)))
        return PlayMediaIntentHandler()
    }
}
