import AppKit
import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var showAdvanced = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Trackpad Edges").font(.title2.bold())
                    Spacer()
                    Button(action: model.showSettings) { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings…").help("Settings (⌘,)")
                }
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(model.protectionStatus.title, systemImage: model.protectionStatus.symbol)
                            .font(.headline).foregroundStyle(model.protectionStatus.color)
                            .accessibilityLabel("Protection status: \(model.protectionStatus.title)")
                        Text(model.userMessage).font(.caption).foregroundStyle(.secondary)
                        if let notice = model.autoStart.notice {
                            HStack(spacing: 6) {
                                Text(notice).font(.caption).foregroundStyle(.orange)
                                Button("Dismiss") { model.autoStart.notice = nil }.buttonStyle(.link).font(.caption)
                            }
                        }
                    }
                    Spacer()
                    if model.running {
                        Button(model.rejectEdges ? "Stop palm rejection" : "Stop observation", action: model.disable)
                            .keyboardShortcut("d", modifiers: .command).controlSize(.large)
                    } else {
                        Button(model.rejectEdges ? "Start palm rejection" : "Start observation") { model.start() }
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canStart)
                    }
                }
                HStack {
                    Picker("Trackpad", selection: $model.selectedID) {
                        Text("Select trackpad").tag(UInt64(0))
                        ForEach(model.devices.filter(\.eligible)) { device in
                            Text("\(device.product) · \(device.transport)").tag(device.id)
                        }
                    }.disabled(model.running)
                    Button("Refresh") { model.refresh() }.disabled(model.running)
                }
                HStack(spacing: 16) {
                    MarginControl(name: "Left", value: $model.margins.left)
                    MarginControl(name: "Right", value: $model.margins.right)
                    MarginControl(name: "Top", value: $model.margins.top)
                    MarginControl(name: "Bottom", value: $model.margins.bottom)
                }
                TrackpadCanvas(model: model)
                Text("Drag the green edges or corners, or enter 0–45%. Margins save automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    AdvancedDiagnosticsView(model: model).padding(.top, 10)
                }
                Divider()
                HStack {
                    Button(AppVersion.description, action: model.showAbout).buttonStyle(.link)
                        .accessibilityLabel("About Trackpad Edges, \(AppVersion.description)")
                    Spacer()
                    Button(model.windowLocation == .dock ? "Minimize" : "Hide window", action: model.hideWindow)
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minWidth: 660, minHeight: 610)
    }
}

struct AdvancedDiagnosticsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Session: \(model.status)").font(.caption).textSelection(.enabled)
            if let device = model.devices.first(where: { $0.id == model.selectedID }) {
                Text("Device ID: \(device.id)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            HStack {
                Toggle("Observation only", isOn: Binding(get: { !model.rejectEdges }, set: { model.rejectEdges = !$0 }))
                    .disabled(model.running)
                Toggle("Record system input events", isOn: Binding(get: { !model.contactsOnly }, set: { model.contactsOnly = !$0 }))
                    .disabled(model.running)
            }
            if !model.contactsOnly { Button("Input Monitoring…", action: model.requestPermission) }
            Text("\(model.frameCount) frames · \(model.eventCount) events · \(model.compositionText)").font(.caption)
            Text(model.diagnosticDelta).font(.system(.caption, design: .monospaced))
            Text(model.filterText).font(.caption).foregroundStyle(.secondary)
            if !model.contactsOnly {
                Text("Recent system input · device and touch identity unknown").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.events.enumerated()), id: \.offset) { _, event in
                            Text(String(format: "%-11@ Δ %6.1f %6.1f · %@ · passed", event.kind as NSString,
                                event.deltaX, event.deltaY, event.assessment.composition.rawValue as NSString))
                                .font(.system(.caption, design: .monospaced))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 130)
            }
            Text(model.gestureText).font(.caption).foregroundStyle(.secondary)
            Text(model.hotKeyStatus).font(.caption)
            Button("Export capture…", action: model.exportCapture)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Startup") {
                VStack(alignment: .leading, spacing: 8) {
                    StartupControl(settings: model.startup)
                    Toggle("Start protection automatically", isOn: Binding(
                        get: { model.autoStart.enabled }, set: model.autoStart.setEnabled))
                    Text("Off by default. When on, protection resumes after launch, wake and trackpad reconnect, unless you stopped it. It pauses itself if protection fails or the app quits unexpectedly twice in a row. Stop it any time with ⌘D or ⌃⌥⌘D.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox("Window") {
                Picker("Minimize to", selection: $model.windowLocation) {
                    ForEach(WindowLocation.allCases) { location in Text(location.title).tag(location) }
                }.padding(8)
            }
            GroupBox("Application") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppVersion.description)
                    Text(Bundle.main.bundleURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("Show app in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                        Button("About Trackpad Edges…", action: model.showAbout)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }.padding(22).frame(width: 450)
    }
}
