import Foundation
import EdgeModel

var assertionCount = 0
func expect(_ expression: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    assertionCount += 1
    guard expression() else {
        FileHandle.standardError.write(Data("FAIL: \(file):\(line)\n".utf8))
        exit(1)
    }
}

struct EdgeModelTests {
    func testAutoStartIsOffUntilEnabledAndRequiresEarlierExplicitStart() {
        var policy = AutoStartPolicy()
        expect(!policy.shouldAutoStart)
        policy.setEnabled(true)
        expect(!policy.shouldAutoStart) // Enabled, but protection was never started.
        policy.sessionStarted(manual: true)
        expect(policy.shouldAutoStart)
        policy.sessionStopped(.user)
        expect(!policy.shouldAutoStart) // A user Stop is respected.
    }

    func testAutoStartResumesAfterInterruptionAndQuitButNotAfterFailure() {
        var policy = AutoStartPolicy()
        policy.setEnabled(true)
        policy.sessionStarted(manual: true)
        policy.sessionStopped(.interrupted)
        expect(policy.shouldAutoStart) // Sleep or disconnect.
        policy.sessionStarted(manual: false)
        policy.appWillQuit()
        policy.appLaunched()
        expect(policy.shouldAutoStart && policy.failures == 0) // Orderly quit is not a crash.
        policy.sessionStarted(manual: false)
        policy.sessionStopped(.failure)
        expect(!policy.shouldAutoStart && policy.failures == 1)
    }

    func testCrashLoopBreakerTripsAfterTwoUncleanLaunchesAndManualStartRearms() {
        var policy = AutoStartPolicy()
        policy.setEnabled(true)
        policy.sessionStarted(manual: true)
        policy.appLaunched() // Previous run died with the session open.
        expect(policy.failures == 1 && !policy.tripped && policy.shouldAutoStart)
        policy.sessionStarted(manual: false)
        policy.appLaunched() // Died again.
        expect(policy.failures == 2 && policy.tripped && !policy.shouldAutoStart)
        policy.sessionStarted(manual: false)
        expect(policy.tripped) // Automatic starts never re-arm.
        policy.sessionStarted(manual: true)
        expect(!policy.tripped && policy.failures == 0 && policy.shouldAutoStart)
    }

    func testStableSessionForgivesFailuresAndDisablingClearsIntent() {
        var policy = AutoStartPolicy()
        policy.setEnabled(true)
        policy.sessionStarted(manual: true)
        policy.appLaunched()
        expect(policy.failures == 1)
        policy.sessionStarted(manual: false)
        policy.sessionStable()
        expect(policy.failures == 0)
        policy.appLaunched() // A later crash starts counting from zero again.
        expect(policy.failures == 0 || policy.failures == 1)
        policy.setEnabled(false)
        expect(!policy.shouldAutoStart && !policy.enabled)
        var plain = AutoStartPolicy()
        plain.sessionStarted(manual: true); plain.appLaunched(); plain.appLaunched()
        expect(!plain.tripped) // The breaker only guards an enabled setting.
    }

    func testFourIndependentMarginsAndInclusiveCenterBoundary() {
        let margins = Margins(left: 0.1, right: 0.2, top: 0.3, bottom: 0.4)
        expect(margins.contains(Contact(id: 1, x: 0.1, y: 0.4)))
        expect(margins.contains(Contact(id: 1, x: 0.8, y: 0.7)))
        for point in [(0.09, 0.5), (0.81, 0.5), (0.5, 0.71), (0.5, 0.39)] {
            expect(!(margins.contains(Contact(id: 1, x: point.0, y: point.1))))
        }
        expect((Margins()) == (Margins(left: 0.1, right: 0.1, top: 0.1, bottom: 0.1)))
    }

    func testMarginsRetainNonemptyCenterAndRejectNonfiniteCoordinates() {
        let margins = Margins(left: -1, right: 1, top: .nan, bottom: .infinity)
        expect((margins.left) == (0))
        expect((margins.right) == (0.45))
        expect((margins.top) == (0.1))
        expect((margins.bottom) == (0.1))
        expect(!(margins.contains(Contact(id: 1, x: .nan, y: 0.5))))
        expect(!(margins.contains(Contact(id: 1, x: 0.5, y: .infinity))))
        expect(!(margins.contains(Contact(id: 1, x: -0.01, y: 0.5))))
    }

    func testPalmOnEdgeDoesNotRemoveCenterFromDiagnosticClassification() {
        let palm = Contact(id: 9, x: 0.02, y: 0.5)
        let center = Contact(id: 1, x: 0.5, y: 0.5)
        expect((composition([palm], margins: Margins(), fresh: true)) == (.edgeOnly))
        expect((composition([center], margins: Margins(), fresh: true)) == (.centerOnly))
        expect((composition([palm, center], margins: Margins(), fresh: true)) == (.mixed))
        expect((composition([], margins: Margins(), fresh: true)) == (.noActiveContacts))
        expect((composition([center], margins: Margins(), fresh: false)) == (.stale))
        expect((composition([Contact(id: 1, state: 2, x: 0.5, y: 0.5)], margins: Margins(), fresh: true)) == (.noActiveContacts))
    }

    func testMarginCrossingAndReturnResetDiagnosticBaselineWithoutJump() {
        var tracker = CenterDeltaTracker()
        let margins = Margins()
        func finger(_ x: Double) -> [Contact] { [Contact(id: 1, x: x, y: 0.5)] }
        expect(tracker.update(finger(0.5), margins: margins).isEmpty)
        expect(abs((tracker.update(finger(0.6), margins: margins)[1]!.x) - (0.1)) < 0.00001)
        expect(tracker.update(finger(0.95), margins: margins).isEmpty)
        expect(tracker.update(finger(0.97), margins: margins).isEmpty)
        expect(tracker.update(finger(0.7), margins: margins).isEmpty)
        expect(abs((tracker.update(finger(0.71), margins: margins)[1]!.x) - (0.01)) < 0.00001)
        expect(tracker.update([], margins: margins).isEmpty)
        expect(tracker.update(finger(0.3), margins: margins).isEmpty)
        tracker.reset()
        expect(tracker.update(finger(0.8), margins: margins).isEmpty)
    }

    func testInvalidAndDuplicateContactFramesResetBaseline() {
        let center = Contact(id: 1, x: 0.5, y: 0.5)
        var tracker = CenterDeltaTracker()
        _ = tracker.update([center], margins: Margins())
        expect((composition([center, center], margins: Margins(), fresh: true)) == (.invalid))
        expect(tracker.update([center, center], margins: Margins()).isEmpty)
        expect(tracker.update([center], margins: Margins()).isEmpty)
        let bad = Contact(id: 1, state: 99, x: 0.5, y: 0.5)
        expect((composition([bad], margins: Margins(), fresh: true)) == (.invalid))
    }

    func testEdgeTimingNeverGrantsPermissionToSuppressUnattributedEvents() {
        for category in [ContactComposition.edgeOnly, .centerOnly, .mixed, .stale, .invalid, .noActiveContacts] {
            let assessment = ShadowAssessment(composition: category)
            expect(!(assessment.safeToSuppress))
            expect((assessment.timingCandidateForEdgeSuppression) == (category == .edgeOnly))
        }
        expect(ShadowAssessment(composition: .mixed).reason.contains("cannot separate"))
    }

    func testMovingEdgePalmDoesNotPolluteCenterDiagnosticDelta() {
        var tracker = CenterDeltaTracker()
        _ = tracker.update([Contact(id: 1, x: 0.5, y: 0.5), Contact(id: 9, x: 0.02, y: 0.1)], margins: Margins())
        let deltas = tracker.update([Contact(id: 1, x: 0.51, y: 0.5), Contact(id: 9, x: 0.03, y: 0.8)], margins: Margins())
        expect((deltas.count) == (1))
        expect(abs((deltas[1]!.x) - (0.01)) < 0.00001)
        expect(deltas[9] == nil)
    }
}

let suite = EdgeModelTests()
suite.testFourIndependentMarginsAndInclusiveCenterBoundary()
print("PASS: testFourIndependentMarginsAndInclusiveCenterBoundary")
suite.testMarginsRetainNonemptyCenterAndRejectNonfiniteCoordinates()
print("PASS: testMarginsRetainNonemptyCenterAndRejectNonfiniteCoordinates")
suite.testPalmOnEdgeDoesNotRemoveCenterFromDiagnosticClassification()
print("PASS: testPalmOnEdgeDoesNotRemoveCenterFromDiagnosticClassification")
suite.testMarginCrossingAndReturnResetDiagnosticBaselineWithoutJump()
print("PASS: testMarginCrossingAndReturnResetDiagnosticBaselineWithoutJump")
suite.testInvalidAndDuplicateContactFramesResetBaseline()
print("PASS: testInvalidAndDuplicateContactFramesResetBaseline")
suite.testEdgeTimingNeverGrantsPermissionToSuppressUnattributedEvents()
print("PASS: testEdgeTimingNeverGrantsPermissionToSuppressUnattributedEvents")
suite.testMovingEdgePalmDoesNotPolluteCenterDiagnosticDelta()
print("PASS: testMovingEdgePalmDoesNotPolluteCenterDiagnosticDelta")
suite.testAutoStartIsOffUntilEnabledAndRequiresEarlierExplicitStart()
print("PASS: testAutoStartIsOffUntilEnabledAndRequiresEarlierExplicitStart")
suite.testAutoStartResumesAfterInterruptionAndQuitButNotAfterFailure()
print("PASS: testAutoStartResumesAfterInterruptionAndQuitButNotAfterFailure")
suite.testCrashLoopBreakerTripsAfterTwoUncleanLaunchesAndManualStartRearms()
print("PASS: testCrashLoopBreakerTripsAfterTwoUncleanLaunchesAndManualStartRearms")
suite.testStableSessionForgivesFailuresAndDisablingClearsIntent()
print("PASS: testStableSessionForgivesFailuresAndDisablingClearsIntent")
print("11 scenarios passed (\(assertionCount) assertions)")
