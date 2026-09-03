import XCTest
@testable import HerdrKit

final class ConnectionRecoveryTests: XCTestCase {
    // MARK: - Foreground decisioning

    func testHeldConnectionIsProvenAfterABackgroundPass() {
        XCTAssertEqual(
            ConnectionRecoveryPolicy.onForeground(liveness: .established, wasSuspended: true),
            .probe
        )
    }

    func testHeldConnectionIsLeftAloneWithoutABackgroundPass() {
        XCTAssertEqual(
            ConnectionRecoveryPolicy.onForeground(liveness: .established, wasSuspended: false),
            .reuse
        )
    }

    func testFailedConnectionRebuildsRatherThanShortCircuiting() {
        XCTAssertEqual(
            ConnectionRecoveryPolicy.onForeground(liveness: .failed, wasSuspended: true),
            .rebuild
        )
        XCTAssertEqual(
            ConnectionRecoveryPolicy.onForeground(liveness: .failed, wasSuspended: false),
            .rebuild
        )
    }

    func testAbsentConnectionRebuilds() {
        XCTAssertEqual(
            ConnectionRecoveryPolicy.onForeground(liveness: .absent, wasSuspended: false),
            .rebuild
        )
    }

    func testInFlightConnectIsNotDisturbed() {
        XCTAssertEqual(
            ConnectionRecoveryPolicy.onForeground(liveness: .establishing, wasSuspended: true),
            .wait
        )
    }

    // MARK: - Probe outcome

    func testFailedProbeIsTerminal() {
        XCTAssertEqual(ConnectionRecoveryPolicy.afterProbe(succeeded: false), .rebuild)
    }

    func testSuccessfulProbeKeepsTheTransport() {
        XCTAssertEqual(ConnectionRecoveryPolicy.afterProbe(succeeded: true), .reuse)
    }

    // MARK: - Attach revision

    func testAttachOnTheCurrentTransportSurvives() {
        XCTAssertFalse(
            ConnectionRecoveryPolicy.attachNeedsRebuild(attachedRevision: 3, currentRevision: 3)
        )
    }

    func testAttachOnAReplacedTransportIsRebuilt() {
        XCTAssertTrue(
            ConnectionRecoveryPolicy.attachNeedsRebuild(attachedRevision: 3, currentRevision: 4)
        )
    }

    func testAttachWithNoRecordedRevisionIsRebuilt() {
        XCTAssertTrue(
            ConnectionRecoveryPolicy.attachNeedsRebuild(attachedRevision: nil, currentRevision: 0)
        )
    }
}
