import Foundation

public struct Contact: Codable, Identifiable, Equatable {
    public let id: Int32
    public let state: Int32
    public let x: Double
    public let y: Double
    public init(id: Int32, state: Int32 = 4, x: Double, y: Double) {
        self.id = id; self.state = state; self.x = x; self.y = y
    }
    public var active: Bool { state == 3 || state == 4 }
    public var valid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}

public struct Margins: Codable, Equatable {
    public var left: Double
    public var right: Double
    public var top: Double
    public var bottom: Double
    public init(left: Double = 0.1, right: Double = 0.1, top: Double = 0.1, bottom: Double = 0.1) {
        // Each side is limited to 45%, so a nonempty center always remains.
        func safe(_ value: Double) -> Double { value.isFinite ? min(0.45, max(0, value)) : 0.1 }
        self.left = safe(left); self.right = safe(right)
        self.top = safe(top); self.bottom = safe(bottom)
    }
    public func contains(_ contact: Contact) -> Bool {
        // Normalized y increases upwards; boundaries belong to the center.
        contact.valid && contact.x >= left && contact.x <= 1 - right
            && contact.y >= bottom && contact.y <= 1 - top
    }
}

public enum ContactComposition: String, Codable {
    case noActiveContacts, centerOnly, edgeOnly, mixed, invalid, stale
}

public func composition(_ contacts: [Contact], margins: Margins, fresh: Bool) -> ContactComposition {
    guard fresh else { return .stale }
    guard contacts.allSatisfy({ $0.valid && (0...7).contains($0.state) }),
          Set(contacts.map(\.id)).count == contacts.count else { return .invalid }
    let active = contacts.filter(\.active)
    guard !active.isEmpty else { return .noActiveContacts }
    let centerCount = active.filter { margins.contains($0) }.count
    if centerCount == 0 { return .edgeOnly }
    if centerCount == active.count { return .centerOnly }
    return .mixed
}

// This is a diagnostic model, not a pointer or gesture replacement engine.
// It demonstrates how a contact's baseline must reset at a margin crossing.
public struct Delta: Codable, Equatable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct CenterDeltaTracker {
    private var previous: [Int32: Contact] = [:]
    public init() {}
    public mutating func reset() { previous.removeAll() }
    public mutating func update(_ contacts: [Contact], margins: Margins) -> [Int32: Delta] {
        guard composition(contacts, margins: margins, fresh: true) != .invalid else { reset(); return [:] }
        let center = contacts.filter { $0.active && margins.contains($0) }
        var result: [Int32: Delta] = [:]
        for contact in center {
            if let old = previous[contact.id] {
                result[contact.id] = Delta(x: contact.x - old.x, y: contact.y - old.y)
            }
        }
        previous = Dictionary(uniqueKeysWithValues: center.map { ($0.id, $0) })
        return result
    }
}

public struct ShadowAssessment: Codable {
    public let composition: ContactComposition
    public let timingCandidateForEdgeSuppression: Bool
    public let safeToSuppress: Bool
    public let reason: String
    public init(composition: ContactComposition) {
        self.composition = composition
        timingCandidateForEdgeSuppression = composition == .edgeOnly
        safeToSuppress = false
        reason = composition == .mixed
            ? "Native event may combine center and edge contributions; cannot separate them."
            : "No verified originating device or touch identity in the observed event."
    }
}
