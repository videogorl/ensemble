import Intents

open class IntentHandler: INExtension {
    public override init() {
        super.init()
        // Log immediately after super.init to confirm the class is instantiated
        SiriExtensionLogger.info("SIRI_EXT: IntentHandler.init() called - extension is loading")
    }

    public override func handler(for intent: INIntent) -> Any {
        SiriExtensionLogger.info("SIRI_EXT: handler(for:) called with intent type: \(String(describing: type(of: intent)))")

        switch intent {
        case is INUpdateMediaAffinityIntent:
            return UpdateMediaAffinityIntentHandler()
        case is INAddMediaIntent:
            return AddMediaIntentHandler()
        default:
            return PlayMediaIntentHandler()
        }
    }
}
