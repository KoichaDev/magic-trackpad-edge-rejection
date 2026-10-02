import SwiftUI

enum ProtectionStatus {
    case active, stopped, observing, disconnected, unavailable, error
    var title: String {
        switch self {
        case .active: return "Active"
        case .stopped: return "Stopped"
        case .observing: return "Observing"
        case .disconnected: return "Disconnected"
        case .unavailable: return "Unavailable"
        case .error: return "Error"
        }
    }
    var menuLabel: String {
        switch self {
        case .active: return "On"
        case .stopped: return "Off"
        case .observing: return "Observe"
        case .disconnected: return "No device"
        case .unavailable: return "Unavailable"
        case .error: return "Error"
        }
    }
    var symbol: String {
        switch self {
        case .active: return "checkmark.shield.fill"
        case .stopped: return "stop.circle"
        case .observing: return "eye"
        case .disconnected: return "antenna.radiowaves.left.and.right.slash"
        case .unavailable: return "questionmark.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
    var color: Color {
        switch self {
        case .active: return .green
        case .error: return .red
        case .disconnected, .unavailable, .observing: return .orange
        case .stopped: return .secondary
        }
    }
}

struct AppVersion {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
    static var description: String { "Version \(version) (build \(build))" }
}
