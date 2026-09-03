import Foundation

/// Where a device connection stands, with no transport or platform detail
/// attached. Clients map their own connection state onto this so the recovery
/// decision below can be exercised without an SSH host.
public enum ConnectionLiveness: Sendable, Equatable {
    /// Never connected, or torn down since.
    case absent
    /// A connect is in flight.
    case establishing
    /// Connected as far as this client last knew.
    case established
    /// The last attempt or the last use failed.
    case failed
}

/// What a client should do with a connection it is about to use again.
public enum ConnectionRecoveryAction: Sendable, Equatable {
    /// Leave it alone — someone else's connect is already running.
    case wait
    /// Keep the held transport.
    case reuse
    /// Prove the held transport on the wire before trusting it.
    case probe
    /// Tear the transport down and build a fresh one.
    case rebuild
}

/// iOS suspends the process without telling the peer, so a held SSH session can
/// come back half-open: the library still believes it is connected while reads
/// never return. Keeping the two decisions that follow from that free of UIKit
/// and libssh2 is what makes them testable.
public enum ConnectionRecoveryPolicy {
    /// The action to take when the app returns to the foreground.
    ///
    /// - Parameter wasSuspended: whether the process was backgrounded since the
    ///   connection was last proven. A foreground pass with no intervening
    ///   background — a dismissed sheet, a phone call banner — must not disturb
    ///   a session that is demonstrably fine.
    public static func onForeground(
        liveness: ConnectionLiveness,
        wasSuspended: Bool
    ) -> ConnectionRecoveryAction {
        switch liveness {
        case .establishing:
            return .wait
        case .absent, .failed:
            return .rebuild
        case .established:
            return wasSuspended ? .probe : .reuse
        }
    }

    /// The action to take once a liveness probe has come back. A probe that
    /// failed is the only honest evidence about a half-open session, so it is
    /// terminal: the transport is rebuilt rather than retried in place.
    public static func afterProbe(succeeded: Bool) -> ConnectionRecoveryAction {
        succeeded ? .reuse : .rebuild
    }

    /// Whether a channel opened on transport revision `attachedRevision` is
    /// still sitting on the transport its owner has now.
    ///
    /// Every reconnect bumps the revision, and every channel opened on the old
    /// transport died with it. Missing that mismatch is what made an in-place
    /// "Reconnect" write into a dead session while backing out of the screen
    /// and re-entering worked.
    public static func attachNeedsRebuild(
        attachedRevision: Int?,
        currentRevision: Int
    ) -> Bool {
        guard let attachedRevision else { return true }
        return attachedRevision != currentRevision
    }
}
