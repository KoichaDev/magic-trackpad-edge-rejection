import AppKit
import ServiceManagement
import SwiftUI

/// macOS is the source of truth, including changes made in System Settings.
/// The app records only whether its one-time question has been answered.
final class StartupSettings: ObservableObject {
    private static let promptAnsweredKey = "startupPromptAnswered.v1"
    private let service = SMAppService.mainApp
    @Published private(set) var registrationStatus: SMAppService.Status = .notRegistered
    @Published private(set) var changing = false
    @Published var errorMessage: String?
    var onChange: (() -> Void)?

    var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    var requested: Bool { registrationStatus == .enabled || registrationStatus == .requiresApproval }
    var needsApproval: Bool { registrationStatus == .requiresApproval }
    var canConfigure: Bool { isAppBundle && !changing }
    var shouldOfferStartup: Bool {
        isAppBundle && !requested && !UserDefaults.standard.bool(forKey: Self.promptAnsweredKey)
    }
    var explanation: String {
        guard isAppBundle else { return "Open the built TrackpadEdges.app to configure startup." }
        switch registrationStatus {
        case .enabled: return "Opens the app when you sign in. Press Start palm rejection to activate filtering."
        case .requiresApproval: return "macOS approval is needed in System Settings → General → Login Items."
        case .notFound: return "Startup is not registered. Turn on Open at login to register this app."
        case .notRegistered: return "Open this app automatically after you sign in to macOS."
        @unknown default: return "Check this app's startup status in macOS Login Items."
        }
    }

    init() { refresh() }
    func refresh() {
        registrationStatus = isAppBundle ? service.status : .notRegistered
        onChange?()
    }
    func markPromptAnswered() { UserDefaults.standard.set(true, forKey: Self.promptAnsweredKey) }
    func setRequested(_ enabled: Bool) {
        guard !changing, isAppBundle else { return }
        markPromptAnswered()
        errorMessage = nil
        refresh()
        guard requested != enabled else { return }
        changing = true
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            errorMessage = "macOS could not \(enabled ? "enable" : "disable") Open at Login: \(error.localizedDescription)"
        }
        changing = false
        refresh() // Reflect the real OS state even when the operation fails.
    }
    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

struct StartupControl: View {
    @ObservedObject var settings: StartupSettings
    var body: some View {
        HStack(spacing: 8) {
            Toggle("Open at login", isOn: Binding(get: { settings.requested }, set: settings.setRequested))
                .disabled(!settings.canConfigure)
                .help(settings.explanation)
            if settings.needsApproval {
                Text("Approval needed").font(.caption).foregroundStyle(.secondary)
                Button("Login Items…", action: settings.openLoginItems)
            }
        }
        .onAppear { settings.refresh() }
        .alert("Could not change startup", isPresented: Binding(
            get: { settings.errorMessage != nil },
            set: { if !$0 { settings.errorMessage = nil } })) {
                Button("OK") { settings.errorMessage = nil }
            } message: { Text(settings.errorMessage ?? "") }
    }
}
