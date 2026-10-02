import AppKit
import SwiftUI
import EdgeModel

enum WindowLocation: String, CaseIterable, Identifiable {
    case dock, menuBar
    var id: String { rawValue }
    var title: String { self == .dock ? "Dock" : "Menu bar" }
}

final class AppModel: ObservableObject {
    private static let marginsPreferenceKey = "edgeMargins.v1"
    private static let windowLocationPreferenceKey = "windowLocation.v1"
    @Published var windowLocation = WindowLocation(rawValue: UserDefaults.standard.string(forKey: windowLocationPreferenceKey) ?? "") ?? .dock {
        didSet {
            UserDefaults.standard.set(windowLocation.rawValue, forKey: Self.windowLocationPreferenceKey)
            onWindowLocationChange?(windowLocation)
        }
    }
    var onWindowLocationChange: ((WindowLocation) -> Void)?
    var onHideWindow: (() -> Void)?
    var onRunningChange: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onShowAbout: (() -> Void)?
    @Published var protectionStatus: ProtectionStatus = .stopped {
        didSet { onRunningChange?() }
    }
    var canStart: Bool { selectedID != 0 && devices.contains { $0.id == selectedID && $0.eligible } }
    var userMessage: String {
        switch protectionStatus {
        case .active: return "Your saved edge margins are being rejected."
        case .observing: return "Observation only. Palm rejection is off."
        case .disconnected: return "Reconnect your Magic Trackpad, then press Start."
        case .unavailable: return "Connect a compatible Bluetooth Magic Trackpad."
        case .error: return status.isEmpty ? "Protection stopped. Open Advanced for the details, then try again." : "Protection stopped: \(status)"
        case .stopped: return canStart ? "Press Start to enable palm rejection." : "Select a trackpad to continue."
        }
    }
    func showSettings() { onShowSettings?() }
    func showAbout() { onShowAbout?() }
    @Published var devices: [DeviceInfo] = []
    @Published var selectedID: UInt64 = 0
    @Published var margins = AppModel.savedMargins() {
        didSet {
            session.store.setMargins(margins); deltaTracker.reset()
            if let data = try? JSONEncoder().encode(margins) {
                UserDefaults.standard.set(data, forKey: Self.marginsPreferenceKey)
            }
        }
    }
    @Published var contacts: [Contact] = []
    @Published var events: [EventSample] = []
    @Published var status = "Disabled"
    @Published var running = false { didSet { onRunningChange?() } }
    @Published var fresh = false
    @Published var frameCount: UInt64 = 0
    @Published var eventCount: UInt64 = 0
    @Published var compositionText = "stale"
    @Published var diagnosticDelta = "No center delta"
    @Published var gestureText = "No AppKit gesture observed in this window"
    @Published var hotKeyStatus = ""
    @Published var contactsOnly = true
    @Published var rejectEdges = true
    @Published var filterText = ""
    let startup = StartupSettings()
    let session = ObservationSession()
    private var deltaTracker = CenterDeltaTracker()
    private var previousSequence: UInt64 = 0
    private var timer: Timer?
    private var healthTimer: Timer?
    private var deviceTimer: Timer?
    private var hasSeenCompatibleDevice = false
    private var gestureMonitor: Any?
    private var hotKey: DisableHotKey?
    private var workspaceTokens: [NSObjectProtocol] = []

    private static func savedMargins() -> Margins {
        guard let data = UserDefaults.standard.data(forKey: marginsPreferenceKey),
              let saved = try? JSONDecoder().decode(Margins.self, from: data) else { return Margins() }
        return Margins(left: saved.left, right: saved.right, top: saved.top, bottom: saved.bottom)
    }

    init() {
        session.store.setMargins(margins)
        session.onStop = { [weak self] reason, kind in
            self?.status = reason
            self?.protectionStatus = kind == .disconnected ? .disconnected : kind == .failure ? .error : .stopped
            self?.running = false; self?.contacts = []
            self?.fresh = false; self?.deltaTracker.reset()
        }
        refresh()
        hotKey = DisableHotKey { [weak self] in self?.disable() }
        let result = hotKey!.register()
        hotKeyStatus = result == 0 ? "Global disable: ⌃⌥⌘D" : "Global shortcut unavailable (\(result)); use Disable or ⌘D in this app"
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.update() }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.session.checkHealth() }
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !self.running else { return }
            self.refresh(clearStatus: false) // Discovery never activates rejection.
        }
        // Local gestures prove only delivery to our window. They are not a global
        // interception or proof that Mission Control/other native gestures survive.
        gestureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .rotate, .swipe, .beginGesture, .endGesture]) { [weak self] event in
            if self?.running == true {
                self?.session.store.localGesture(event)
                self?.gestureText = "AppKit event \(event.type.rawValue), phase \(event.phase.rawValue) (this window only)"
            }
            return event
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceTokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.session.stop(reason: "Sleep/session change; explicit restart required", kind: .sessionChange)
            })
        }
    }
    func refresh(clearStatus: Bool = true) {
        guard !running else { return }
        do {
            devices = try enumerateDevices()
            let eligible = devices.filter(\.eligible)
            if !eligible.contains(where: { $0.id == selectedID }) { selectedID = eligible.count == 1 ? eligible[0].id : 0 }
            if eligible.isEmpty {
                protectionStatus = hasSeenCompatibleDevice ? .disconnected : .unavailable
                status = "No compatible Bluetooth Magic Trackpad available"
            } else {
                hasSeenCompatibleDevice = true
                if clearStatus || protectionStatus == .disconnected || protectionStatus == .unavailable {
                    protectionStatus = .stopped
                    status = "Ready. Start palm rejection when you need it."
                }
            }
        } catch {
            protectionStatus = .error; status = String(describing: error)
        }
    }
    func start() {
        guard let selected = devices.first(where: { $0.id == selectedID && $0.eligible }) else {
            status = "Select a Bluetooth Magic Trackpad first"; return
        }
        do {
            try session.start(device: selected, observeEvents: !contactsOnly, rejectEdges: rejectEdges)
            previousSequence = 0; deltaTracker.reset()
            status = session.status; protectionStatus = rejectEdges ? .active : .observing; running = true
        } catch { session.stop(reason: String(describing: error), kind: .failure) }
    }
    func disable() { if running { session.stop(reason: "Stopped by user", kind: .user) } }
    func hideWindow() { onHideWindow?() }
    func update() {
        let filter = FilterSummary()
        filterText = "\(filter.packets) raw packets · \(filter.removedContactSamples) rejected contact samples · \(filter.blockedClicks) blocked clicks"
        let snapshot = session.store.snapshot()
        frameCount = snapshot.2; eventCount = snapshot.3; events = snapshot.1
        guard running, let frame = snapshot.0 else {
            contacts = []; fresh = false; compositionText = "stale"; diagnosticDelta = "No center delta"; return
        }
        let age = ProcessInfo.processInfo.systemUptime - frame.receivedUptime
        fresh = age >= 0 && age <= 0.15
        contacts = frame.contacts
        compositionText = composition(contacts, margins: margins, fresh: fresh).rawValue
        if !fresh { deltaTracker.reset(); diagnosticDelta = "Frame stale; baseline reset" }
        if frame.sequence != previousSequence {
            previousSequence = frame.sequence
            let deltas = deltaTracker.update(fresh ? contacts : [], margins: margins)
            diagnosticDelta = deltas.sorted { $0.key < $1.key }.map {
                String(format: "#%d Δ %.4f, %.4f", $0.key, $0.value.x, $0.value.y)
            }.joined(separator: "   ")
            if diagnosticDelta.isEmpty { diagnosticDelta = "No center delta (baseline/new/edge contact)" }
        }
    }
    func requestPermission() {
        _ = CGRequestListenEventAccess()
        status = "Grant Input Monitoring in System Settings, then start again. Relaunch if macOS asks."
    }
    func exportCapture() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "trackpad-observation.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try writeJSON(session.store.capture(device: session.device, status: session.status), to: url) }
        catch { status = "Export failed: \(error)" }
    }
    func shutdown() {
        disable(); timer?.invalidate(); healthTimer?.invalidate(); deviceTimer?.invalidate()
        if let gestureMonitor { NSEvent.removeMonitor(gestureMonitor) }
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceTokens = []; hotKey = nil
    }
}
