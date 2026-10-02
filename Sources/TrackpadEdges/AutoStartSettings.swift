import Foundation
import EdgeModel

/// Persists `AutoStartPolicy` and exposes it to SwiftUI. Opt-in and off by default.
final class AutoStartSettings: ObservableObject {
    private static let key = "autoStart.v1"
    static let stableSessionSeconds: TimeInterval = 30
    @Published private(set) var policy: AutoStartPolicy
    @Published var notice: String?
    private var stableTimer: Timer?
    private var quitting = false

    init() {
        var saved = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(AutoStartPolicy.self, from: $0) } ?? AutoStartPolicy()
        saved.appLaunched()
        policy = saved
        save()
        if saved.tripped { notice = Self.trippedNotice }
    }

    static let trippedNotice = "Automatic start was paused because protection failed or the app quit unexpectedly more than once. Press Start palm rejection to turn it back on."

    var enabled: Bool { policy.enabled }
    var shouldAutoStart: Bool { policy.shouldAutoStart }

    func setEnabled(_ value: Bool) {
        policy.setEnabled(value)
        if value { notice = nil }
        save()
    }

    func sessionStarted(manual: Bool) {
        policy.sessionStarted(manual: manual)
        if manual { notice = nil }
        save()
        stableTimer?.invalidate()
        stableTimer = Timer.scheduledTimer(withTimeInterval: Self.stableSessionSeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.policy.sessionStable(); self.save()
        }
    }

    func sessionStopped(_ kind: AutoStartPolicy.StopKind) {
        stableTimer?.invalidate(); stableTimer = nil
        guard !quitting else { return } // Quitting must not erase the intent to resume.
        policy.sessionStopped(kind)
        if policy.tripped && notice == nil { notice = Self.trippedNotice }
        save()
    }

    func appWillQuit() {
        quitting = true
        stableTimer?.invalidate(); stableTimer = nil
        policy.appWillQuit(); save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(policy) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
