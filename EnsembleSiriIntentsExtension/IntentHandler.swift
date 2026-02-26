import Intents
import os

final class IntentHandler: INExtension {
    private let logger = Logger(subsystem: "com.videogorl.ensemble.siri-intents", category: "IntentHandler")

    override func handler(for intent: INIntent) -> Any {
        logger.debug("handler(for:): intent=\(String(describing: type(of: intent)), privacy: .public)")
        return PlayMediaIntentHandler()
    }
}
