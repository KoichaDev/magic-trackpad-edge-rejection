import Foundation

/// Pure decision logic for opt-in auto-start and its crash-loop breaker.
/// Persistence and timers live in the app; this type only answers "may we
/// start protection on our own?" and records what happened.
public struct AutoStartPolicy: Codable, Equatable, Sendable {
    public static let failureLimit = 2

    public enum StopKind: Sendable { case user, interrupted, failure }

    /// The user turned the setting on.
    public private(set) var enabled = false
    /// Protection was on and nobody asked it to stop, so it should come back.
    public private(set) var wantActive = false
    /// A session started and has not ended cleanly. Still set at launch means
    /// the previous run crashed or was killed.
    public private(set) var sessionOpen = false
    /// Consecutive unclean exits and failed sessions without a stable run.
    public private(set) var failures = 0
    /// The breaker fired: automatic starts are suspended until a manual Start.
    public private(set) var tripped = false

    public init() {}

    public var shouldAutoStart: Bool { enabled && wantActive && !tripped }

    public mutating func setEnabled(_ value: Bool) {
        enabled = value
        if value { failures = 0; tripped = false }
        else { wantActive = false }
    }

    /// Call once at launch, before deciding whether to auto-start.
    public mutating func appLaunched() {
        if sessionOpen { failures += 1; sessionOpen = false }
        updateTrip()
    }

    /// `manual` starts re-arm a tripped breaker; automatic ones never do.
    public mutating func sessionStarted(manual: Bool) {
        if manual { failures = 0; tripped = false }
        sessionOpen = true
        wantActive = true
    }

    /// The session ran healthily for long enough to forgive earlier failures.
    public mutating func sessionStable() { failures = 0 }

    public mutating func sessionStopped(_ kind: StopKind) {
        sessionOpen = false
        switch kind {
        case .user: wantActive = false
        case .interrupted: break // Sleep or disconnect: protection should resume.
        case .failure: wantActive = false; failures += 1; updateTrip()
        }
    }

    /// Orderly quit: not a crash, and the user's intent is kept for next launch.
    public mutating func appWillQuit() { sessionOpen = false }

    private mutating func updateTrip() {
        if enabled && failures >= Self.failureLimit { tripped = true }
    }
}
