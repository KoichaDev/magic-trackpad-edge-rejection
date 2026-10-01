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
    let session = ObservationSession()
    private var deltaTracker = CenterDeltaTracker()
    private var previousSequence: UInt64 = 0
    private var timer: Timer?
    private var healthTimer: Timer?
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
        session.onStop = { [weak self] reason in
            self?.status = reason; self?.running = false; self?.contacts = []
            self?.fresh = false; self?.deltaTracker.reset()
        }
        refresh()
        hotKey = DisableHotKey { [weak self] in self?.disable() }
        let result = hotKey!.register()
        hotKeyStatus = result == 0 ? "Global disable: ⌃⌥⌘D" : "Global shortcut unavailable (\(result)); use Disable or ⌘D in this app"
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.update() }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.session.checkHealth() }
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
                self?.session.stop(reason: "Sleep/session change; explicit restart required")
            })
        }
    }
    func refresh() {
        do {
            devices = try enumerateDevices()
            let eligible = devices.filter(\.eligible)
            if !eligible.contains(where: { $0.id == selectedID }) { selectedID = eligible.count == 1 ? eligible[0].id : 0 }
            if eligible.isEmpty { status = "No verified Bluetooth Magic Trackpad available" }
        } catch { status = String(describing: error) }
    }
    func start() {
        guard let selected = devices.first(where: { $0.id == selectedID && $0.eligible }) else {
            status = "Select a Bluetooth Magic Trackpad first"; return
        }
        do {
            try session.start(device: selected, observeEvents: !contactsOnly, rejectEdges: rejectEdges)
            previousSequence = 0; deltaTracker.reset()
            status = session.status; running = true
        } catch { session.stop(reason: String(describing: error)) }
    }
    func disable() { session.stop(reason: "Stopped by user") }
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
        disable(); timer?.invalidate(); healthTimer?.invalidate()
        if let gestureMonitor { NSEvent.removeMonitor(gestureMonitor) }
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceTokens = []; hotKey = nil
    }
}

private enum CanvasResizeHandle: String, CaseIterable, Identifiable {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var adjustsLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var adjustsRight: Bool { self == .right || self == .topRight || self == .bottomRight }
    var adjustsTop: Bool { self == .top || self == .topLeft || self == .topRight }
    var adjustsBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    var corner: Bool { (adjustsLeft || adjustsRight) && (adjustsTop || adjustsBottom) }
    var label: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
    var cursor: NSCursor {
        corner ? .crosshair : (adjustsLeft || adjustsRight ? .resizeLeftRight : .resizeUpDown)
    }
    func position(in center: CGRect) -> CGPoint {
        CGPoint(x: adjustsLeft ? center.minX : adjustsRight ? center.maxX : center.midX,
                y: adjustsTop ? center.minY : adjustsBottom ? center.maxY : center.midY)
    }
}

struct TrackpadCanvas: View {
    @ObservedObject var model: AppModel
    @State private var resizeOrigin: Margins?
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let center = CGRect(x: size.width * model.margins.left, y: size.height * model.margins.top,
                width: size.width * (1 - model.margins.left - model.margins.right),
                height: size.height * (1 - model.margins.top - model.margins.bottom))
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.red.opacity(0.12))
                Path { $0.addRect(center) }.fill(Color.green.opacity(0.16))
                Path { $0.addRect(center) }.stroke(Color.green.opacity(0.6), lineWidth: 1)
                Text("CENTER").font(.caption).foregroundStyle(.secondary)
                    .position(x: center.midX, y: center.midY).allowsHitTesting(false)
                ForEach(model.contacts) { contact in
                    let color: Color = !contact.active ? .gray : model.margins.contains(contact) ? .green : .red
                    ZStack {
                        Circle().fill(color.opacity(model.fresh ? 0.9 : 0.25)).frame(width: 24, height: 24)
                        Text("\(contact.id)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }.position(x: size.width * contact.x, y: size.height * (1 - contact.y))
                        .allowsHitTesting(false)
                }
                ForEach(CanvasResizeHandle.allCases) { handle in
                    resizeHandle(handle, center: center, size: size)
                }
            }
            .coordinateSpace(name: "trackpadCanvas")
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.gray.opacity(0.4)).allowsHitTesting(false))
        }
        .frame(height: 290)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trackpad canvas. Drag the green edges or corners to resize the center.")
    }
    private func resizeHandle(_ handle: CanvasResizeHandle, center: CGRect, size: CGSize) -> some View {
        let vertical = handle.adjustsLeft || handle.adjustsRight
        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.green)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.85), lineWidth: 1))
            .frame(width: handle.corner ? 12 : vertical ? 6 : 24,
                   height: handle.corner ? 12 : vertical ? 24 : 6)
            .frame(width: handle.corner || vertical ? 24 : max(24, center.width - 24),
                   height: handle.corner || !vertical ? 24 : max(24, center.height - 24))
            .contentShape(Rectangle())
            .onHover { inside in (inside ? handle.cursor : NSCursor.arrow).set() }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trackpadCanvas"))
                .onChanged { drag in
                    guard size.width > 0, size.height > 0 else { return }
                    if resizeOrigin == nil { resizeOrigin = model.margins }
                    let origin = resizeOrigin ?? model.margins
                    resize(handle, origin: origin,
                           dx: drag.translation.width / size.width, dy: drag.translation.height / size.height)
                }
                .onEnded { _ in resizeOrigin = nil })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Resize \(handle.label.lowercased()) margin")
            .accessibilityAdjustableAction { direction in
                let step: Double
                switch direction {
                case .increment: step = 0.01
                case .decrement: step = -0.01
                @unknown default: return
                }
                resize(handle, origin: model.margins,
                       dx: handle.adjustsRight ? -step : step, dy: handle.adjustsBottom ? -step : step)
            }
            .help("Drag to resize the \(handle.label.lowercased()) margin")
            .position(handle.position(in: center))
    }
    private func resize(_ handle: CanvasResizeHandle, origin: Margins, dx: Double, dy: Double) {
        func percent(_ value: Double) -> Double { min(0.45, max(0, (value * 100).rounded() / 100)) }
        let margins = Margins(
            left: handle.adjustsLeft ? percent(origin.left + dx) : origin.left,
            right: handle.adjustsRight ? percent(origin.right - dx) : origin.right,
            top: handle.adjustsTop ? percent(origin.top + dy) : origin.top,
            bottom: handle.adjustsBottom ? percent(origin.bottom - dy) : origin.bottom)
        if margins != model.margins { model.margins = margins }
    }
}

private struct MarginControl: View {
    let name: String
    @Binding var value: Double
    @State private var percentText = ""
    @FocusState private var editingPercent: Bool
    private var displayedPercent: String { String(Int((value * 100).rounded())) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(name).font(.caption)
                Spacer(minLength: 4)
                TextField("0", text: $percentText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 48)
                    .focused($editingPercent)
                    .accessibilityLabel("\(name) margin percentage")
                    .onSubmit(commitPercentage)
                Text("%").font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...0.45, step: 0.01)
                .accessibilityLabel("\(name) margin")
        }
        .onAppear { percentText = displayedPercent }
        .onChange(of: value) { _, _ in percentText = displayedPercent }
        .onChange(of: percentText) { _, text in
            guard editingPercent, let number = Int(text.trimmingCharacters(in: .whitespaces)),
                  (0...45).contains(number) else { return }
            let margin = Double(number) / 100
            if value != margin { value = margin }
        }
        .onChange(of: editingPercent) { _, editing in if !editing { commitPercentage() } }
    }
    private func commitPercentage() {
        if let number = Int(percentText.trimmingCharacters(in: .whitespaces)) {
            let margin = Double(min(45, max(0, number))) / 100
            if value != margin { value = margin }
        }
        percentText = displayedPercent
    }
}

struct PrototypeView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Magic Trackpad · Palm rejection").font(.title2.bold())
            HStack {
                Text(model.rejectEdges ? "Native palm rejection · runs until stopped" : "Observation only · input passes unchanged")
                    .foregroundStyle(model.running && model.rejectEdges ? .green : .secondary).font(.headline)
                Spacer()
                Picker("Minimize to", selection: $model.windowLocation) {
                    ForEach(WindowLocation.allCases) { location in Text(location.title).tag(location) }
                }.fixedSize()
                Button(model.windowLocation == .dock ? "Minimize" : "Hide window", action: model.hideWindow)
                    .help("Keep palm rejection running and restore the window from the \(model.windowLocation.title).")
            }
            HStack {
                Picker("Device", selection: $model.selectedID) {
                    Text("Select trackpad").tag(UInt64(0))
                    ForEach(model.devices.filter(\.eligible)) { device in
                        Text("\(device.product) · \(device.transport) · \(device.id)").tag(device.id)
                    }
                }.disabled(model.running)
                Button("Refresh", action: model.refresh).disabled(model.running)
            }
            HStack {
                Toggle("Reject edges", isOn: $model.rejectEdges).disabled(model.running)
                Toggle("Contacts only", isOn: $model.contactsOnly).disabled(model.running)
                Spacer()
                Button("Input Monitoring…", action: model.requestPermission)
                Button(model.rejectEdges ? "Start palm rejection" : "Start observation", action: model.start)
                    .disabled(model.running || model.selectedID == 0)
                Button(model.rejectEdges ? "Stop palm rejection" : "Stop observation", action: model.disable)
                    .keyboardShortcut("d", modifiers: .command).disabled(!model.running)
            }
            HStack(spacing: 18) {
                MarginControl(name: "Left", value: $model.margins.left)
                MarginControl(name: "Right", value: $model.margins.right)
                MarginControl(name: "Top", value: $model.margins.top)
                MarginControl(name: "Bottom", value: $model.margins.bottom)
            }
            TrackpadCanvas(model: model)
            Text("Drag an edge or corner to resize the center. Enter a percentage from 0 to 45.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(model.status).fontWeight(.medium)
                Spacer()
                Text("\(model.frameCount) frames · \(model.eventCount) events · \(model.compositionText)")
            }.font(.caption)
            Text(model.diagnosticDelta).font(.system(.caption, design: .monospaced))
            Text(model.filterText).font(.caption).foregroundStyle(.secondary)
            Text("Recent system input · device and touch identity unknown").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.events.enumerated()), id: \.offset) { _, event in
                        Text(String(format: "%-11@ Δ %6.1f %6.1f · %@ · %@", event.kind as NSString,
                            event.deltaX, event.deltaY, event.assessment.composition.rawValue as NSString,
                            event.assessment.timingCandidateForEdgeSuppression ? "timing candidate; passed" : "passed"))
                            .font(.system(.caption, design: .monospaced))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 130)
            Text(model.gestureText).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(model.hotKeyStatus).font(.caption)
                Spacer()
                Button("Export capture…", action: model.exportCapture)
            }
        }.padding(20).frame(minWidth: 840, minHeight: 830)
    }
}

// Route the title-bar minimize button and ⌘M through the same saved preference.
final class TrackpadWindow: NSWindow {
    var minimizeToMenuBar = false
    override func miniaturize(_ sender: Any?) {
        if minimizeToMenuBar { orderOut(sender) } else { super.miniaturize(sender) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var model: AppModel?
    var window: TrackpadWindow?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        let model = AppModel(); self.model = model
        let window = TrackpadWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 850),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Trackpad Edges — Palm rejection"
        window.delegate = self
        window.contentView = NSHostingView(rootView: PrototypeView(model: model))
        window.center(); self.window = window
        model.onWindowLocationChange = { [weak self] in self?.applyWindowLocation($0) }
        model.onHideWindow = { [weak self] in self?.window?.miniaturize(nil) }
        model.onRunningChange = { [weak self] in self?.updateStatusItem() }
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let submenu = NSMenu(); item.submenu = submenu
        submenu.addItem(menuItem("Show Trackpad Edges", action: #selector(showWindow(_:)), key: "0"))
        submenu.addItem(menuItem("Minimize", action: #selector(minimizeWindow(_:)), key: "m"))
        submenu.addItem(.separator())
        submenu.addItem(withTitle: "Quit Trackpad Edges", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu; menu.addItem(editItem)
        NSApp.mainMenu = menu
        applyWindowLocation(model.windowLocation)
        showWindow(nil)
    }

    private func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func applyWindowLocation(_ location: WindowLocation) {
        window?.minimizeToMenuBar = location == .menuBar
        if location == .menuBar {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                let menu = NSMenu(); menu.delegate = self
                item.menu = menu; statusItem = item
            }
            updateStatusItem()
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
        }
    }

    private func updateStatusItem() {
        guard let model, let statusItem else { return }
        let active = model.running && model.rejectEdges
        let state = active ? "Palm rejection active" : model.running ? "Observation active" : "Palm rejection stopped"
        let icon = NSImage(systemSymbolName: active ? "hand.raised.fill" : "hand.raised", accessibilityDescription: state)
        icon?.size = NSSize(width: 18, height: 18); icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.toolTip = "Trackpad Edges — \(state)"
        statusItem.button?.setAccessibilityLabel("Trackpad Edges — \(state)")
        if let menu = statusItem.menu { populateStatusMenu(menu, state: state) }
    }

    private func populateStatusMenu(_ menu: NSMenu, state: String) {
        guard let model else { return }
        menu.removeAllItems()
        menu.addItem(menuItem("Show Trackpad Edges", action: #selector(showWindow(_:))))
        let stateItem = NSMenuItem(title: state, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false; menu.addItem(stateItem)
        menu.addItem(.separator())
        let title = model.running ? (model.rejectEdges ? "Stop palm rejection" : "Stop observation") : "Start palm rejection"
        let toggle = menuItem(title, action: #selector(toggleRejection(_:)))
        toggle.isEnabled = model.running || model.selectedID != 0
        menu.addItem(toggle)
        let locationItem = NSMenuItem(title: "Minimize to", action: nil, keyEquivalent: "")
        let locations = NSMenu(); locations.autoenablesItems = false
        let dock = menuItem("Dock", action: #selector(chooseDock(_:)))
        let menuBar = menuItem("Menu bar", action: #selector(chooseMenuBar(_:)))
        dock.state = model.windowLocation == .dock ? .on : .off
        menuBar.state = model.windowLocation == .menuBar ? .on : .off
        locations.addItem(dock); locations.addItem(menuBar)
        locationItem.submenu = locations; menu.addItem(locationItem)
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Trackpad Edges", action: #selector(quit(_:))))
        menu.autoenablesItems = false
    }

    func menuWillOpen(_ menu: NSMenu) { updateStatusItem() }
    @objc private func showWindow(_ sender: Any?) {
        if window?.isMiniaturized == true { window?.deminiaturize(sender) }
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func minimizeWindow(_ sender: Any?) { window?.miniaturize(sender) }
    @objc private func toggleRejection(_ sender: Any?) {
        guard let model else { return }
        if model.running { model.disable() } else { model.rejectEdges = true; model.start() }
        updateStatusItem()
    }
    @objc private func chooseDock(_ sender: Any?) { model?.windowLocation = .dock; showWindow(sender) }
    @objc private func chooseMenuBar(_ sender: Any?) { model?.windowLocation = .menuBar }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(sender) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model?.windowLocation == .menuBar { sender.orderOut(nil); return false }
        return true
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(nil); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { model?.windowLocation != .menuBar }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}
