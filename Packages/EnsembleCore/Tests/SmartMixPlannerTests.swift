@testable import EnsembleCore
import XCTest

final class SmartMixPlannerTests: XCTestCase {
    func testPlanUsesDefaultTenSecondTransitionForNormalTracks() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 180,
            incomingDuration: 200,
            outgoingAnalysis: .unavailable,
            incomingAnalysis: .unavailable
        )

        XCTAssertEqual(plan?.transitionDuration, 10)
        XCTAssertEqual(plan?.outgoingStartTime, 170)
        XCTAssertEqual(plan?.incomingStartTime, 10)
        XCTAssertEqual(plan?.metadataPromotionTime, 5)
        XCTAssertEqual(plan?.skipToIncomingThreshold, 5)
    }

    func testPlanTrimsOutgoingSilenceBeforeChoosingTransitionStart() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 180,
            incomingDuration: 200,
            outgoingAnalysis: SmartMixAnalysis(leadingSilence: 0, trailingSilence: 7, analyzedDuration: 180),
            incomingAnalysis: .unavailable
        )

        XCTAssertEqual(plan?.transitionDuration, 10)
        XCTAssertEqual(plan?.outgoingStartTime, 163)
    }

    func testPlanCutsIntoIncomingPastDetectedIntroSilence() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 180,
            incomingDuration: 200,
            outgoingAnalysis: .unavailable,
            incomingAnalysis: SmartMixAnalysis(leadingSilence: 6, trailingSilence: 0, analyzedDuration: 200)
        )

        XCTAssertEqual(plan?.incomingStartTime, 10)
    }

    func testPlanClampsShortTracksBelowDefaultTransition() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 14,
            incomingDuration: 16,
            outgoingAnalysis: .unavailable,
            incomingAnalysis: .unavailable
        )

        XCTAssertEqual(plan?.transitionDuration, 7)
        XCTAssertEqual(plan?.metadataPromotionTime, 3.5)
        XCTAssertEqual(plan?.skipToIncomingThreshold, 3.5)
    }

    func testPlanRejectsTracksTooShortForSmartMix() {
        XCTAssertNil(
            SmartMixPlanner.plan(
                outgoingDuration: 8,
                incomingDuration: 180,
                outgoingAnalysis: .unavailable,
                incomingAnalysis: .unavailable
            )
        )
        XCTAssertNil(
            SmartMixPlanner.plan(
                outgoingDuration: 180,
                incomingDuration: 8,
                outgoingAnalysis: .unavailable,
                incomingAnalysis: .unavailable
            )
        )
    }

    func testShouldStartTransitionHonorsTolerance() {
        let plan = SmartMixPlan(
            transitionDuration: 10,
            outgoingStartTime: 170,
            incomingStartTime: 10,
            metadataPromotionTime: 5,
            skipToIncomingThreshold: 5
        )

        XCTAssertFalse(SmartMixPlanner.shouldStartTransition(currentTime: 169.5, plan: plan))
        XCTAssertTrue(SmartMixPlanner.shouldStartTransition(currentTime: 169.7, plan: plan))
        XCTAssertTrue(SmartMixPlanner.shouldStartTransition(currentTime: 170, plan: plan))
    }
}
