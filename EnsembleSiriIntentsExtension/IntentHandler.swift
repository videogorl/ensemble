import Intents
import os

open class IntentHandler: INExtension {
    private let logger = Logger(subsystem: "com.videogorl.ensemble.siri-intents", category: "IntentHandler")

    public override func handler(for intent: INIntent) -> Any {
        logger.debug("handler(for:): intent=\(String(describing: type(of: intent)), privacy: .public)")
        return PlayMediaIntentHandler()
    }
}
