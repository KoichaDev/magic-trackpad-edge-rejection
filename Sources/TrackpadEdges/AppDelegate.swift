import AppKit
import SwiftUI

// Route the title-bar minimize button and ⌘M through the same saved preference.
final class TrackpadWindow: NSWindow {
    var minimizeToMenuBar = false
    var onMenuBarHide: (() -> Void)?
    override func miniaturize(_ sender: Any?) {
        if minimizeToMenuBar {
            orderOut(sender); onMenuBarHide?()
        } else { super.miniaturize(sender) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var model: AppModel?
    var window: TrackpadWindow?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        restoreAppIcon()
        let model = AppModel(); self.model = model
        let window = TrackpadWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 670),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Trackpad Edges — Palm rejection"
        window.delegate = self
        window.onMenuBarHide = { NSApp.setActivationPolicy(.accessory) }
        window.contentView = NSHostingView(rootView: MainView(model: model))
        window.center(); self.window = window
        model.onWindowLocationChange = { [weak self] in self?.applyWindowLocation($0) }
        model.onHideWindow = { [weak self] in self?.window?.miniaturize(nil) }
        model.onRunningChange = { [weak self] in self?.updateStatusItem() }
        model.onShowSettings = { [weak self] in self?.showSettings(nil) }
        model.onShowAbout = { [weak self] in self?.showAbout(nil) }
        model.startup.onChange = { [weak self] in self?.updateStatusItem() }
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let submenu = NSMenu(); item.submenu = submenu
        submenu.addItem(menuItem("About Trackpad Edges…", action: #selector(showAbout(_:))))
        submenu.addItem(menuItem("Settings…", action: #selector(showSettings(_:)), key: ","))
        submenu.addItem(.separator())
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
        DispatchQueue.main.async { [weak self] in self?.offerStartup() }
    }

    private func offerStartup() {
        guard let model, let window, model.startup.shouldOfferStartup else { return }
        let alert = NSAlert()
        alert.messageText = "Open Trackpad Edges when you sign in?"
        alert.informativeText = "The app can open automatically when you sign in to macOS after a restart or shutdown. Your saved margins will be restored. Press Start palm rejection to activate filtering. You can change this anytime in Settings."
        alert.addButton(withTitle: "Open at Login")
        alert.addButton(withTitle: "Not Now")
        alert.beginSheetModal(for: window) { [weak model] response in
            guard let model else { return }
            model.startup.markPromptAnswered()
            if response == .alertFirstButtonReturn { model.startup.setRequested(true) }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { model?.startup.refresh() }

    private func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func restoreAppIcon() {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
    }

    private func applyWindowLocation(_ location: WindowLocation) {
        window?.minimizeToMenuBar = location == .menuBar
        // Always retain a menu bar entry, including in Dock mode, so changing the
        // minimize destination never removes the user's access to quick controls.
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu(); menu.delegate = self
            item.menu = menu; statusItem = item
        }
        updateStatusItem()
        if location == .dock || window?.isVisible == true {
            NSApp.setActivationPolicy(.regular)
            restoreAppIcon()
        }
    }

    private func updateStatusItem() {
        guard let model, let statusItem else { return }
        let state = "Palm rejection: \(model.protectionStatus.title)"
        let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        let icon = iconURL.flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "hand.raised", accessibilityDescription: state)
        icon?.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = icon
        statusItem.button?.title = " \(model.protectionStatus.menuLabel)"
        statusItem.button?.imagePosition = .imageLeading
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
        toggle.isEnabled = model.running || model.canStart
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
        let startup = menuItem("Open at Login", action: #selector(toggleStartup(_:)))
        startup.state = model.startup.requested ? .on : .off
        startup.isEnabled = model.startup.canConfigure
        menu.addItem(startup)
        if model.startup.needsApproval {
            menu.addItem(menuItem("Approve in Login Items…", action: #selector(openLoginItems(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", action: #selector(showSettings(_:))))
        menu.addItem(menuItem("About Trackpad Edges…", action: #selector(showAbout(_:))))
        menu.addItem(menuItem("Quit Trackpad Edges", action: #selector(quit(_:))))
        menu.autoenablesItems = false
    }

    func menuWillOpen(_ menu: NSMenu) { model?.startup.refresh() }
    @objc private func toggleStartup(_ sender: Any?) {
        guard let model else { return }
        model.startup.setRequested(!model.startup.requested)
        if model.startup.errorMessage != nil { showWindow(sender) }
    }
    @objc private func openLoginItems(_ sender: Any?) { model?.startup.openLoginItems() }
    @objc private func showWindow(_ sender: Any?) {
        // Showing the controls restores the original Dock icon. Menu bar mode
        // removes it only when the user actually hides/minimizes the window.
        NSApp.setActivationPolicy(.regular)
        restoreAppIcon()
        if window?.isMiniaturized == true { window?.deminiaturize(sender) }
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func showSettings(_ sender: Any?) {
        guard let model else { return }
        if settingsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 360),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Trackpad Edges — Settings"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: SettingsView(model: model))
            panel.center(); settingsWindow = panel
        }
        NSApp.setActivationPolicy(.regular); restoreAppIcon()
        settingsWindow?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func showAbout(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular); restoreAppIcon()
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Trackpad Edges",
            .applicationVersion: "\(AppVersion.version) (build \(AppVersion.build))",
            .version: ""
        ]
        if let icon = NSApp.applicationIconImage { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
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
        if model?.windowLocation == .menuBar { window?.miniaturize(nil); return false }
        NSApp.terminate(sender)
        return false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(nil); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { model?.windowLocation != .menuBar }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}
