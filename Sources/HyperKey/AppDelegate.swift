import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotkeyManager: HotkeyManager!
    private var windowManager: WindowManager!
    private var config: Config!
    private var lastDisplayIndex: Int = -1
    private var mouseMonitor: Any?
    private var configWatcher: DispatchSourceFileSystemObject?

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = Config.load()

        windowManager = WindowManager()
        windowManager.gap = config.gap

        hotkeyManager = HotkeyManager { [weak self] hotkey in
            self?.handleHotkey(hotkey)
        }

        if !hotkeyManager.start() {
            showAccessibilityAlert()
            return
        }

        registerHotkeys()

        // Apply built-in Hyper setting from config
        hotkeyManager.useBuiltInHyper = config.useBuiltInHyper

        setupStatusBar()

        // Maximize all windows on startup
        windowManager.maximizeAllWindows(gap: config.gap)

        // Setup focus border
        windowManager.setupBorderWindow()

        // Track current display in status bar
        startDisplayTracking()

        // Watch for layout mode changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(layoutModeChanged),
            name: .layoutModeChanged,
            object: nil
        )

        // Watch config file for hot reload
        startConfigWatcher()

        #if DEBUG
        print("HyperWM running")
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup mouse monitor
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }

        // Cleanup config watcher
        configWatcher?.cancel()
        configWatcher = nil

        // Cleanup hotkey manager
        hotkeyManager.stop()

        // Cleanup notification observers
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "HyperWM") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageLeading
            }
            updateStatusBarTitle()
        }

        let menu = NSMenu()

        // Toggle options (grouped first)
        let borderItem = NSMenuItem(title: "Show Active Window Border", action: #selector(toggleBorder), keyEquivalent: "")
        borderItem.state = .on
        menu.addItem(borderItem)

        let hyperItem = NSMenuItem(title: "Use Built-In Hyper (Caps Lock)", action: #selector(toggleBuiltInHyper), keyEquivalent: "")
        hyperItem.state = config.useBuiltInHyper ? .on : .off
        menu.addItem(hyperItem)

        let focusItem = NSMenuItem(title: "Focus Follows Mouse", action: #selector(toggleFocusFollowsMouse), keyEquivalent: "")
        focusItem.state = .off
        menu.addItem(focusItem)

        menu.addItem(NSMenuItem.separator())

        // Layout submenu
        let layoutMenu = NSMenu()
        let fullItem = NSMenuItem(title: "Full", action: #selector(setLayoutFull), keyEquivalent: "")
        fullItem.state = .on
        layoutMenu.addItem(fullItem)
        let bspItem = NSMenuItem(title: "BSP (Master-Stack)", action: #selector(setLayoutBSP), keyEquivalent: "")
        bspItem.state = .off
        layoutMenu.addItem(bspItem)
        let layoutMenuItem = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        layoutMenuItem.submenu = layoutMenu
        menu.addItem(layoutMenuItem)

        // Gaps submenu
        let gapsMenu = NSMenu()
        for gap in [0, 5, 10, 15, 20] {
            let item = NSMenuItem(title: gap == 0 ? "None (0)" : "\(gap)px", action: #selector(setGap(_:)), keyEquivalent: "")
            item.tag = gap
            item.state = gap == config.gap ? .on : .off
            gapsMenu.addItem(item)
        }
        let gapsMenuItem = NSMenuItem(title: "Gaps", action: nil, keyEquivalent: "")
        gapsMenuItem.submenu = gapsMenu
        menu.addItem(gapsMenuItem)

        menu.addItem(NSMenuItem.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Restart", action: #selector(restart), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: ""))
        statusItem.menu = menu
    }

    private func updateStatusBarTitle() {
        let modes = windowManager.getAllDisplayModes()
        let title = modes.map { display in
            let modeChar = display.mode == .full ? "F" : "B"
            return "\(display.index + 1)\(modeChar)"
        }.joined(separator: " ")
        statusItem.button?.title = " \(title)"
    }

    @objc private func layoutModeChanged(_ notification: Notification) {
        updateStatusBarTitle()
    }

    // MARK: - Display Tracking

    private func startDisplayTracking() {
        updateDisplayNumber()

        // Event-driven: only update when mouse moves
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.updateDisplayNumber()
        }
    }

    private func updateDisplayNumber() {
        let mouseLocation = NSEvent.mouseLocation

        var displayIndex = 0
        for (index, screen) in NSScreen.screens.enumerated() {
            if screen.frame.contains(mouseLocation) {
                displayIndex = index
                break
            }
        }

        // Early exit: only update if changed
        guard displayIndex != lastDisplayIndex else { return }
        lastDisplayIndex = displayIndex
        updateStatusBarTitle()
    }

    // MARK: - Config Hot Reload (FSEvents)

    private func startConfigWatcher() {
        let path = Config.configPath.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            #if DEBUG
            print("Could not open config file for watching")
            #endif
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            #if DEBUG
            print("Config file changed, reloading...")
            #endif
            self?.reloadConfig()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        configWatcher = source
    }

    @objc private func toggleBorder(_ sender: NSMenuItem) {
        windowManager.borderEnabled.toggle()
        sender.state = windowManager.borderEnabled ? .on : .off
    }

    @objc private func setLayoutFull(_ sender: NSMenuItem) {
        let currentMode = windowManager.getMode(forDisplay: windowManager.currentDisplayIndex)
        if currentMode != .full {
            windowManager.setLayoutMode(.full)
        }
        updateLayoutMenuState()
    }

    @objc private func setLayoutBSP(_ sender: NSMenuItem) {
        let currentMode = windowManager.getMode(forDisplay: windowManager.currentDisplayIndex)
        if currentMode != .bsp {
            windowManager.setLayoutMode(.bsp)
        }
        updateLayoutMenuState()
    }

    private func updateLayoutMenuState() {
        guard let menu = statusItem.menu,
              let layoutItem = menu.item(withTitle: "Layout"),
              let layoutMenu = layoutItem.submenu else { return }

        let currentMode = windowManager.getMode(forDisplay: windowManager.currentDisplayIndex)
        for item in layoutMenu.items {
            if item.title == "Full" {
                item.state = currentMode == .full ? .on : .off
            } else if item.title.hasPrefix("BSP") {
                item.state = currentMode == .bsp ? .on : .off
            }
        }
    }

    @objc private func setGap(_ sender: NSMenuItem) {
        let newGap = sender.tag
        config.gap = newGap
        windowManager.gap = newGap
        windowManager.retileAllScreens()

        // Update menu checkmarks
        guard let menu = statusItem.menu,
              let gapsItem = menu.item(withTitle: "Gaps"),
              let gapsMenu = gapsItem.submenu else { return }

        for item in gapsMenu.items {
            item.state = item.tag == newGap ? .on : .off
        }
    }

    @objc private func toggleBuiltInHyper(_ sender: NSMenuItem) {
        config.useBuiltInHyper.toggle()
        hotkeyManager.useBuiltInHyper = config.useBuiltInHyper
        sender.state = config.useBuiltInHyper ? .on : .off
        config.save()

        #if DEBUG
        print("Built-in Hyper: \(config.useBuiltInHyper ? "enabled" : "disabled")")
        #endif
    }

    @objc private func toggleFocusFollowsMouse(_ sender: NSMenuItem) {
        windowManager.focusFollowsMouse.toggle()
        sender.state = windowManager.focusFollowsMouse ? .on : .off

        #if DEBUG
        print("Focus Follows Mouse: \(windowManager.focusFollowsMouse ? "enabled" : "disabled")")
        #endif
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newState = !isLaunchAtLoginEnabled()
        setLaunchAtLogin(newState)
        sender.state = newState ? .on : .off
    }

    private var launchAgentPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.hyperwm.plist")
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPath.path)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            // Get the actual executable path
            let executablePath = ProcessInfo.processInfo.arguments[0]

            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.hyperwm</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(executablePath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
            </dict>
            </plist>
            """
            try? plist.write(to: launchAgentPath, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: launchAgentPath)
        }
    }

    @objc private func restart() {
        let executablePath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executablePath)
        try? task.run()
        NSApplication.shared.terminate(nil)
    }

    @objc private func reloadConfig() {
        config = Config.load()

        // Apply all settings
        windowManager.gap = config.gap
        windowManager.borderEnabled = true
        windowManager.focusFollowsMouse = false
        windowManager.setLayoutModeForAllDisplays(.full)
        hotkeyManager.useBuiltInHyper = config.useBuiltInHyper
        registerHotkeys()

        // Update menu states
        updateGapsMenuState()
        updateHyperMenuState()
        updateLayoutMenuState()
        updateBorderMenuState()
        updateFocusFollowsMouseMenuState()

        // Retile to apply changes
        windowManager.retileAllScreens()

        #if DEBUG
        print("Config reloaded")
        #endif
    }

    private func updateHyperMenuState() {
        guard let menu = statusItem.menu,
              let hyperItem = menu.item(withTitle: "Use Built-In Hyper (Caps Lock)") else { return }
        hyperItem.state = config.useBuiltInHyper ? .on : .off
    }

    private func updateGapsMenuState() {
        guard let menu = statusItem.menu,
              let gapsItem = menu.item(withTitle: "Gaps"),
              let gapsMenu = gapsItem.submenu else { return }

        for item in gapsMenu.items {
            item.state = item.tag == config.gap ? .on : .off
        }
    }

    private func updateBorderMenuState() {
        guard let menu = statusItem.menu,
              let borderItem = menu.item(withTitle: "Show Active Window Border") else { return }
        borderItem.state = windowManager.borderEnabled ? .on : .off
    }

    private func updateFocusFollowsMouseMenuState() {
        guard let menu = statusItem.menu,
              let focusItem = menu.item(withTitle: "Focus Follows Mouse") else { return }
        focusItem.state = windowManager.focusFollowsMouse ? .on : .off
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        hotkeyManager.clearHotkeys()

        for binding in config.bindings {
            hotkeyManager.register(
                keyCode: binding.keyCode,
                modifiers: binding.modifierFlags,
                id: binding.id
            )
        }
    }

    private func handleHotkey(_ id: String) {
        updateDisplayNumber()  // Update immediately on hotkey
        guard let binding = config.bindings.first(where: { $0.id == id }) else { return }

        switch binding.action {
        case .toggleApp(let bundleId):
            windowManager.toggleApp(bundleId: bundleId)

        case .toggleBraveProfile(let profile):
            windowManager.toggleBraveProfile(profile: profile)

        case .cycleWindows:
            windowManager.cycleWindows()

        case .moveToNextScreen:
            windowManager.moveToOtherDisplay(gap: config.gap)

        case .toggleLayoutMode:
            windowManager.toggleLayoutMode()

        case .focusDisplay(let index):
            windowManager.focusDisplay(index: index)

        case .toggleFloat:
            windowManager.toggleFloatFocused()
        }
    }

    // MARK: - Accessibility Alert

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "HyperWM needs accessibility access to manage windows and capture hotkeys.\n\nGo to System Settings → Privacy & Security → Accessibility and enable HyperWM."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        NSApplication.shared.terminate(nil)
    }
}
