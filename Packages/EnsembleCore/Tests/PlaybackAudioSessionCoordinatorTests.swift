import XCTest
@testable import EnsembleCore
#if !os(macOS)
import AVFoundation
#endif

final class PlaybackAudioSessionCoordinatorTests: XCTestCase {
    func testActivationRetriesUntilTheAudioSessionBecomesAvailable() async {
        var attempts = 0
        var releases = 0
        let activated = await PlaybackAudioSessionCoordinator.activateWithRetry(
            attempts: 4,
            delayNanoseconds: 0,
            activate: {
                attempts += 1
                if attempts < 3 {
                    throw NSError(domain: NSOSStatusErrorDomain, code: 560_557_684)
                }
            },
            releaseSession: {
                releases += 1
            }
        )

        XCTAssertTrue(activated)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(releases, 2)
    }

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
