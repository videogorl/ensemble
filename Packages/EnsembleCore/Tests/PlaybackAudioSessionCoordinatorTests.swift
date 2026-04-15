import XCTest
@testable import EnsembleCore
#if !os(macOS)
import AVFoundation
#endif

final class PlaybackAudioSessionCoordinatorTests: XCTestCase {
    func testObserversForwardInterruptionAndRouteChangeNotifications() async {
        #if !os(macOS)
        let notificationCenter = NotificationCenter()
        let coordinator = PlaybackAudioSessionCoordinator(notificationCenter: notificationCenter)
        let interruptionExpectation = expectation(description: "interruption")
        let routeChangeExpectation = expectation(description: "routeChange")

        coordinator.startObserving(
            onInterruption: { _ in
                interruptionExpectation.fulfill()
            },
            onRouteChange: { _ in
                routeChangeExpectation.fulfill()
            }
        )

        notificationCenter.post(name: AVAudioSession.interruptionNotification, object: nil)
        notificationCenter.post(name: AVAudioSession.routeChangeNotification, object: nil)

        await fulfillment(of: [interruptionExpectation, routeChangeExpectation], timeout: 1.0)
        coordinator.stopObserving()
        #endif
    }
}
