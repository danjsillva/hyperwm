import Cocoa
import ApplicationServices

// MARK: - Notification Names
extension Notification.Name {
    static let windowManagerNeedsRetile = Notification.Name("windowManagerNeedsRetile")
    static let layoutModeChanged = Notification.Name("layoutModeChanged")
    static let hotkeyPressed = Notification.Name("hotkeyPressed")
}

// =============================================================================
// MARK: - CORE RULES
// =============================================================================
//
// RULE 1: NEVER auto-switch displays
//   - Display only changes via explicit focusDisplay() (Hyper+1/2)
//   - All other actions keep focus on current display
//
// RULE 2: ALWAYS retile after any change
//   - Window opened/closed/hidden → retile
//   - Mode changed → retile ALL displays
//   - This applies to BOTH full and bsp modes
//
// RULE 3: Windows MUST respect layout
//   - Enforce layout only when changes detected
//   - Event-driven, not constant polling
//
// =============================================================================

enum LayoutMode {
    case full
    case bsp
}

class WindowManager {
    private var modePerDisplay: [Int: LayoutMode] = [:]  // Layout mode per display index
    var gap: Int = 10

    func getMode(forDisplay index: Int) -> LayoutMode {
        modePerDisplay[index] ?? .full
    }

    func setMode(_ mode: LayoutMode, forDisplay index: Int) {
        modePerDisplay[index] = mode
        NotificationCenter.default.post(name: .layoutModeChanged, object: nil)
        retileAllScreens()
    }

    var currentDisplayIndex: Int {
        let mouseLocation = NSEvent.mouseLocation
        guard let focusedScreen = NSScreen.screens.first(where: { screen in
            mouseLocation.x >= screen.frame.minX && mouseLocation.x < screen.frame.maxX
        }) else { return 0 }
        return NSScreen.screens.firstIndex(of: focusedScreen) ?? 0
    }
    var borderEnabled: Bool = true {
        didSet {
            if borderEnabled {
                updateBorder()
            } else {
                borderWindow?.orderOut(nil)
            }
        }
    }

    var focusFollowsMouse: Bool = false {
        didSet {
            if focusFollowsMouse {
                startFocusFollowsMouse()
            } else {
                stopFocusFollowsMouse()
            }
        }
    }

    private var focusMouseMonitor: Any?
    private var lastFocusedPID: pid_t = 0
    private var borderWindow: BorderWindow?

    // MARK: - Focus Follows Mouse

    private func startFocusFollowsMouse() {
        stopFocusFollowsMouse()

        focusMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMoved()
        }
    }

    private func stopFocusFollowsMouse() {
        if let monitor = focusMouseMonitor {
            NSEvent.removeMonitor(monitor)
            focusMouseMonitor = nil
        }
        lastFocusedPID = 0
    }

    private func handleMouseMoved() {
        let mouseLocation = NSEvent.mouseLocation

        // Find window under cursor
        guard let windowUnderMouse = getWindowUnderPoint(mouseLocation) else { return }

        var pid: pid_t = 0
        AXUIElementGetPid(windowUnderMouse, &pid)

        // Skip if already focused on this app
        guard pid != lastFocusedPID else { return }

        // Skip if it's HyperWM itself
        if pid == ProcessInfo.processInfo.processIdentifier { return }

        lastFocusedPID = pid

        // Focus the window
        AXUIElementPerformAction(windowUnderMouse, kAXRaiseAction as CFString)
        if let app = getAppForWindow(windowUnderMouse) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func getWindowUnderPoint(_ nsPoint: NSPoint) -> AXUIElement? {
        // Convert NS coordinates to AX coordinates (flip Y)
        let axPoint = CGPoint(x: nsPoint.x, y: mainScreenHeight - nsPoint.y)

        refreshAppsCacheIfNeeded()

        for app in regularAppsCache {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }

            for window in windows {
                guard isStandardWindow(window) else { continue }

                var minimizedRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
                   let minimized = minimizedRef as? Bool, minimized { continue }

                let frame = getWindowFrame(window)
                if frame.contains(axPoint) {
                    return window
                }
            }
        }
        return nil
    }

    // MARK: - Timing Constants (unified debounce values)
    private enum Timing {
        static let retileDebounce: Double = 0.1      // Debounce for retile scheduling
        static let activationDelay: Double = 0.05    // Delay after activation for UI to settle
        static let launchDelay: Double = 0.3         // Delay after launching new app
    }

    // Track last focused window per screen (by screen hash)
    private var lastFocusedWindowPID: [Int: pid_t] = [:]
    private var lastFocusedWindowTitle: [Int: String] = [:]

    // PERFORMANCE: Cache mainScreenHeight (updated on screen change)
    private var mainScreenHeight: CGFloat = 0

    // PERFORMANCE: Cache profile directories (loaded once)
    private var profileDirCache: [String: String] = [:]
    private var profileCacheLoaded = false

    // PERFORMANCE: Event-driven retiling instead of constant timer
    private var retileScheduled = false

    // AX Observer for window move/resize events (replaces polling timer)
    private var windowObserver: AXObserver?
    private var observedWindow: AXUIElement?

    // PERFORMANCE: Cache regular apps and PID mapping (updated on app launch/terminate)
    private var regularAppsCache: [NSRunningApplication] = []
    private var pidToAppCache: [pid_t: NSRunningApplication] = [:]
    private var appsCacheValid = false

    // Manually floated windows (by PID + title hash)
    private var manuallyFloatedWindows: Set<String> = []

    // Apps that should always float (not tiled)
    private let floatingApps: Set<String> = [
        "com.apple.systempreferences",
        "com.apple.SystemPreferences",
        "com.apple.calculator",
        "com.apple.ColorSyncUtility",
        "com.apple.DigitalColorMeter",
        "com.apple.Grapher",
        "com.apple.keychainaccess",
        "com.apple.DiskUtility",
        "com.apple.Console",
        "com.apple.ScreenSharing",
        "com.apple.FontBook",
        "com.apple.airport.airportutility",
        "com.apple.BluetoothFileExchange",
        "com.apple.screenshot.launcher",
        "com.apple.Preview",
        "com.1password.1password",
        "com.raycast.macos",
        "com.contextsformac.Contexts",
        "com.hegenberg.BetterTouchTool",
        "com.hegenberg.BetterSnapTool",
        "org.pqrs.Karabiner-Elements",
        "org.pqrs.Karabiner-EventViewer",
    ]

    // Minimum size for tiled windows (smaller = floating)
    private let minTiledWidth: CGFloat = 600
    private let minTiledHeight: CGFloat = 400

    // PERFORMANCE: Static constant for floating subroles (not recreated every call)
    private static let floatingSubroles: Set<String> = [
        kAXDialogSubrole as String,
        kAXSystemDialogSubrole as String,
        kAXFloatingWindowSubrole as String,
        "AXSheet",
    ]

    // MARK: - Init / Deinit

    init() {
        updateMainScreenHeight()
    }

    deinit {
        // Cleanup AX Observer
        if let observer = windowObserver {
            if let window = observedWindow {
                AXObserverRemoveNotification(observer, window, kAXMovedNotification as CFString)
                AXObserverRemoveNotification(observer, window, kAXResizedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
        }

        // Cleanup NotificationCenter observers
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func updateMainScreenHeight() {
        mainScreenHeight = NSScreen.screens.first?.frame.height ?? 900
    }

    private func screenHash(_ screen: NSScreen) -> Int {
        return Int(screen.frame.origin.x) * 10000 + Int(screen.frame.origin.y)
    }

    private func saveCurrentFocus() {
        guard let window = getFocusedWindow() else { return }
        let frame = getWindowFrame(window)
        guard let screen = screenContaining(axPoint: CGPoint(x: frame.midX, y: frame.midY)) else { return }

        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let hash = screenHash(screen)
        lastFocusedWindowPID[hash] = pid

        // Also save title to distinguish same-app windows (e.g., Brave profiles)
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        lastFocusedWindowTitle[hash] = (titleRef as? String) ?? ""
    }

    private func restoreFocusOnScreen(_ screen: NSScreen) -> Bool {
        let hash = screenHash(screen)
        guard let savedPID = lastFocusedWindowPID[hash] else { return false }
        let savedTitle = lastFocusedWindowTitle[hash] ?? ""

        let windows = getWindowsOnScreen(screen, includeFloating: true)

        // PERFORMANCE: Single pass - collect exact match and PID-only match
        var exactMatch: AXUIElement?
        var pidMatch: AXUIElement?

        for window in windows {
            var pid: pid_t = 0
            AXUIElementGetPid(window, &pid)
            guard pid == savedPID else { continue }

            // Found PID match
            if pidMatch == nil { pidMatch = window }

            // Check for exact title match
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            if (titleRef as? String) == savedTitle {
                exactMatch = window
                break  // Found exact match, no need to continue
            }
        }

        // Prefer exact match, fall back to PID match
        guard let targetWindow = exactMatch ?? pidMatch else { return false }

        AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
        if let app = getAppForWindow(targetWindow) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        return true
    }

    private var currentScreen: NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            if screen.frame.contains(mouseLocation) {
                return screen
            }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: - Setup

    func setupBorderWindow() {
        borderWindow = BorderWindow()
        updateBorder()

        let nc = NSWorkspace.shared.notificationCenter

        // Observe app activation changes - also updates window observer
        nc.addObserver(self, selector: #selector(appActivated),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // PERFORMANCE: Event-driven retiling + cache invalidation
        nc.addObserver(self, selector: #selector(appsChanged),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appsChanged),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(scheduleRetile),
                       name: NSWorkspace.didHideApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(scheduleRetile),
                       name: NSWorkspace.didUnhideApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(scheduleRetile),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        // Screen configuration changes
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // AX Observer callback (window move/resize) - memory-safe via NotificationCenter
        NotificationCenter.default.addObserver(self, selector: #selector(handleWindowChangeNotification),
                                               name: .windowManagerNeedsRetile, object: nil)

        // Initial retile
        scheduleRetile()

        // Setup AX observer for focused window (replaces polling timer)
        setupWindowObserver()
    }

    // MARK: - AX Observer (Event-driven window move/resize detection)

    private func setupWindowObserver() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier

        // Create observer for this app
        var observer: AXObserver?
        let result = AXObserverCreate(pid, { (observer, element, notification, refcon) in
            // Use DispatchQueue to safely call back without retaining self in callback
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .windowManagerNeedsRetile, object: nil)
            }
        }, &observer)

        guard result == .success, let observer = observer else { return }

        // Get focused window
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else { return }

        let windowElement = window as! AXUIElement

        // Register for move and resize notifications (no refcon needed - using NotificationCenter)
        AXObserverAddNotification(observer, windowElement, kAXMovedNotification as CFString, nil)
        AXObserverAddNotification(observer, windowElement, kAXResizedNotification as CFString, nil)

        // Add observer to run loop
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)

        // Store references
        self.windowObserver = observer
        self.observedWindow = windowElement
    }

    private func updateWindowObserver() {
        // Remove old observer from run loop
        if let oldObserver = windowObserver {
            if let oldWindow = observedWindow {
                AXObserverRemoveNotification(oldObserver, oldWindow, kAXMovedNotification as CFString)
                AXObserverRemoveNotification(oldObserver, oldWindow, kAXResizedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(oldObserver), .commonModes)
        }
        windowObserver = nil
        observedWindow = nil

        // Setup new observer for current focused window
        setupWindowObserver()
    }

    @objc private func handleWindowChangeNotification() {
        scheduleRetile()
    }

    @objc private func screenChanged() {
        updateMainScreenHeight()
        scheduleRetile()
    }

    @objc private func appsChanged() {
        invalidateAppsCache()
        scheduleRetile()
    }

    // MARK: - Apps Cache

    private func invalidateAppsCache() {
        appsCacheValid = false
    }

    private func refreshAppsCacheIfNeeded() {
        guard !appsCacheValid else { return }
        regularAppsCache = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        pidToAppCache = Dictionary(uniqueKeysWithValues: regularAppsCache.map { ($0.processIdentifier, $0) })
        appsCacheValid = true
    }

    @objc private func appActivated(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.activationDelay) { [weak self] in
            self?.updateBorder()
            self?.updateWindowObserver()  // Track new focused window for move/resize
        }
    }

    @objc private func scheduleRetile() {
        guard !retileScheduled else { return }
        retileScheduled = true

        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.retileDebounce) { [weak self] in
            guard let self = self else { return }
            self.retileScheduled = false
            self.enforceLayout()
        }
    }

    private func enforceLayout() {
        for screen in NSScreen.screens {
            retileScreen(screen)
        }
        updateBorder()
    }

    private func updateBorder() {
        guard borderEnabled else {
            borderWindow?.orderOut(nil)
            return
        }
        guard let window = getFocusedWindow() else {
            borderWindow?.orderOut(nil)
            return
        }
        let frame = getWindowFrame(window)
        guard frame.width > 0 && frame.height > 0 else {
            borderWindow?.orderOut(nil)
            return
        }
        borderWindow?.show(around: frame, screenHeight: mainScreenHeight)
    }

    // MARK: - Floating Window Detection

    private func shouldFloat(window: AXUIElement, app: NSRunningApplication) -> Bool {
        // Check if manually floated
        if isManuallyFloated(window) {
            return true
        }

        if let bundleId = app.bundleIdentifier, floatingApps.contains(bundleId) {
            return true
        }

        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef)
        if let subrole = subroleRef as? String, Self.floatingSubroles.contains(subrole) {
            return true
        }

        let frame = getWindowFrame(window)
        if frame.width < minTiledWidth * 0.8 || frame.height < minTiledHeight * 0.8 {
            return true
        }

        return false
    }

    // MARK: - Toggle App

    func toggleApp(bundleId: String) {
        let targetScreen = currentScreen

        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId
        }) else {
            launchApp(bundleId: bundleId, on: targetScreen)
            return
        }

        if app.isActive {
            app.hide()
            scheduleRetile()  // Retile handles border update via enforceLayout
        } else {
            if app.isHidden { app.unhide() }
            unminimizeWindows(for: app)

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement], let window = windows.first {
                maximizeWindowOnScreen(window, screen: targetScreen)
            }

            app.activate(options: [.activateIgnoringOtherApps])
            scheduleRetile()  // Retile handles border update via enforceLayout
        }
    }

    private func launchApp(bundleId: String, on screen: NSScreen) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + Timing.launchDelay) {
                    self?.scheduleRetile()
                }
            }
        }
    }

    // MARK: - Toggle Brave Profile
    //
    // macOS limitation: can't hide individual windows, only entire apps.
    // Solution: only ONE Brave profile visible at a time, using native app.hide()/unhide()

    func toggleBraveProfile(profile: String) {
        let targetScreen = currentScreen
        let bundleId = "com.brave.Browser"

        guard let braveApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId
        }) else {
            launchBraveProfile(profile: profile, on: targetScreen)
            return
        }

        // Get all Brave windows
        let appElement = AXUIElementCreateApplication(braveApp.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let allBraveWindows = windowsRef as? [AXUIElement] else {
            launchBraveProfile(profile: profile, on: targetScreen)
            return
        }

        // Find the window for THIS profile (use suffix match for accuracy)
        var profileWindow: AXUIElement?

        for window in allBraveWindows {
            guard isStandardWindow(window) else { continue }

            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String) ?? ""

            // Brave format: "Page Title - Profile Name" or just "Profile Name"
            if title.hasSuffix(" - \(profile)") || title == profile {
                profileWindow = window
                break
            }
        }

        guard let targetWindow = profileWindow else {
            // No window found for this profile - launch it
            launchBraveProfile(profile: profile, on: targetScreen)
            return
        }

        // Check if this profile is currently focused (use same suffix match)
        let isProfileFocused: Bool = {
            guard braveApp.isActive, let focused = getFocusedWindow() else { return false }
            var focusedTitleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(focused, kAXTitleAttribute as CFString, &focusedTitleRef)
            let focusedTitle = (focusedTitleRef as? String) ?? ""
            return focusedTitle.hasSuffix(" - \(profile)") || focusedTitle == profile
        }()

        if isProfileFocused {
            // HIDE: This profile is focused, hide the app
            braveApp.hide()
        } else {
            // SHOW: Bring this profile to front
            if braveApp.isHidden { braveApp.unhide() }
            maximizeWindowOnScreen(targetWindow, screen: targetScreen)
            AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
            braveApp.activate(options: [.activateIgnoringOtherApps])
        }
        scheduleRetile()  // Handles border update via enforceLayout
    }

    private func isMinimized(_ window: AXUIElement) -> Bool {
        var minimizedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
           let minimized = minimizedRef as? Bool {
            return minimized
        }
        return false
    }

    private func launchBraveProfile(profile: String, on screen: NSScreen) {
        let bundleId = "com.brave.Browser"
        if let braveApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            let appElement = AXUIElementCreateApplication(braveApp.processIdentifier)
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement] {
                for window in windows {
                    var titleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                    let title = (titleRef as? String) ?? ""

                    // Use consistent suffix match for profile detection
                    let isProfileWindow = title.hasSuffix(" - \(profile)") || title == profile
                    if isProfileWindow && isMinimized(window) {
                        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                        maximizeWindowOnScreen(window, screen: screen)
                        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                        braveApp.activate(options: [.activateIgnoringOtherApps])
                        scheduleRetile()
                        return
                    }
                }
            }
        }

        // PERFORMANCE: Use cached profile directory
        let profileDir = getCachedProfileDirectory(for: profile)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-na", "Brave Browser", "--args", "--profile-directory=\(profileDir)"]
        try? task.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.launchDelay) { [weak self] in
            self?.scheduleRetile()
        }
    }

    // PERFORMANCE: Cache profile directories
    private func getCachedProfileDirectory(for profileName: String) -> String {
        if let cached = profileDirCache[profileName] {
            return cached
        }

        if !profileCacheLoaded {
            loadProfileCache()
        }

        return profileDirCache[profileName] ?? profileName
    }

    private func loadProfileCache() {
        profileCacheLoaded = true

        let localStatePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser/Local State")

        guard let data = try? Data(contentsOf: localStatePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let infoCache = profile["info_cache"] as? [String: Any] else {
            return
        }

        for (dirName, meta) in infoCache {
            if let metaDict = meta as? [String: Any],
               let name = metaDict["name"] as? String {
                profileDirCache[name] = dirName
            }
        }
    }

    // MARK: - Toggle Safari Profile

    func toggleSafariProfile(profile: String) {
        let targetScreen = currentScreen
        let bundleId = "com.apple.Safari"

        guard let safariApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId
        }) else {
            launchSafariProfile(profile: profile, on: targetScreen)
            return
        }

        // Get all Safari windows
        let appElement = AXUIElementCreateApplication(safariApp.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let allSafariWindows = windowsRef as? [AXUIElement] else {
            launchSafariProfile(profile: profile, on: targetScreen)
            return
        }

        // Find the window for THIS profile
        // Safari format: "Page Title — Profile Name" or "Profile Name — Page Title"
        var profileWindow: AXUIElement?

        for window in allSafariWindows {
            guard isStandardWindow(window) else { continue }

            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String) ?? ""

            // Safari uses em-dash (—) as separator
            if title.contains(" — \(profile)") || title.hasPrefix("\(profile) — ") || title == profile {
                profileWindow = window
                break
            }
        }

        guard let targetWindow = profileWindow else {
            launchSafariProfile(profile: profile, on: targetScreen)
            return
        }

        // Check if this profile is currently focused
        let isProfileFocused: Bool = {
            guard safariApp.isActive, let focused = getFocusedWindow() else { return false }
            var focusedTitleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(focused, kAXTitleAttribute as CFString, &focusedTitleRef)
            let focusedTitle = (focusedTitleRef as? String) ?? ""
            return focusedTitle.contains(" — \(profile)") || focusedTitle.hasPrefix("\(profile) — ") || focusedTitle == profile
        }()

        if isProfileFocused {
            safariApp.hide()
        } else {
            if safariApp.isHidden { safariApp.unhide() }
            maximizeWindowOnScreen(targetWindow, screen: targetScreen)
            AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
            safariApp.activate(options: [.activateIgnoringOtherApps])
        }
        scheduleRetile()
    }

    private func launchSafariProfile(profile: String, on screen: NSScreen) {
        let bundleId = "com.apple.Safari"
        if let safariApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            let appElement = AXUIElementCreateApplication(safariApp.processIdentifier)
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement] {
                for window in windows {
                    var titleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                    let title = (titleRef as? String) ?? ""

                    let isProfileWindow = title.contains(" — \(profile)") || title.hasPrefix("\(profile) — ") || title == profile
                    if isProfileWindow && isMinimized(window) {
                        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                        maximizeWindowOnScreen(window, screen: screen)
                        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                        safariApp.activate(options: [.activateIgnoringOtherApps])
                        scheduleRetile()
                        return
                    }
                }
            }
        }

        // Open new Safari window with profile via menu: File → "New {profile} Window"
        if let safariApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            safariApp.activate(options: [.activateIgnoringOtherApps])

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.clickSafariNewProfileWindow(pid: safariApp.processIdentifier, profile: profile, screen: screen)
            }
        } else if let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: safariURL, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                guard let app = app else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.clickSafariNewProfileWindow(pid: app.processIdentifier, profile: profile, screen: screen)
                }
            }
        }
    }

    private func clickSafariNewProfileWindow(pid: pid_t, profile: String, screen: NSScreen) {
        let app = AXUIElementCreateApplication(pid)

        // Get menu bar
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else { return }

        // Get menu bar items (Apple, Safari, File, Edit, ...)
        var menuBarItemsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &menuBarItemsRef) == .success,
              let menuBarItems = menuBarItemsRef as? [AXUIElement] else { return }

        // Find "File" menu (index 2, after Apple and Safari menus)
        guard menuBarItems.count > 2 else { return }
        let fileMenu = menuBarItems[2]

        // Get File menu's submenu
        var fileSubmenuRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(fileMenu, kAXChildrenAttribute as CFString, &fileSubmenuRef) == .success,
              let fileSubmenus = fileSubmenuRef as? [AXUIElement],
              let fileSubmenu = fileSubmenus.first else { return }

        // Get menu items
        var menuItemsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(fileSubmenu, kAXChildrenAttribute as CFString, &menuItemsRef) == .success,
              let menuItems = menuItemsRef as? [AXUIElement] else { return }

        // Find "New {profile} Window" menu item
        let targetTitle = "New \(profile) Window"
        for item in menuItems {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleRef)
            if let title = titleRef as? String, title == targetTitle {
                AXUIElementPerformAction(item, kAXPressAction as CFString)

                DispatchQueue.main.asyncAfter(deadline: .now() + Timing.launchDelay) { [weak self] in
                    self?.scheduleRetile()
                }
                return
            }
        }
    }

    // MARK: - Move to Other Display

    func moveToOtherDisplay(gap: Int) {
        let stayOnScreen = currentScreen

        guard let window = getFocusedWindow() else { return }
        let screens = NSScreen.screens
        guard screens.count > 1 else { return }

        guard let currentIndex = screens.firstIndex(of: stayOnScreen) else { return }
        let otherIndex = (currentIndex + 1) % screens.count
        let otherScreen = screens[otherIndex]

        maximizeWindowOnScreen(window, screen: otherScreen)

        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.activationDelay) { [weak self] in
            guard let self = self else { return }
            self.retileScreen(stayOnScreen)
            self.retileScreen(otherScreen)

            let remainingWindows = self.getWindowsOnScreen(stayOnScreen)
            if let nextWindow = remainingWindows.first, let app = self.getAppForWindow(nextWindow) {
                AXUIElementPerformAction(nextWindow, kAXRaiseAction as CFString)
                app.activate(options: [.activateIgnoringOtherApps])
            } else {
                self.moveMouse(to: stayOnScreen)
            }
            self.updateBorder()
        }
    }

    // MARK: - Layout Mode

    func toggleLayoutMode() {
        // Toggle layout on current display
        let index = currentDisplayIndex
        let currentMode = getMode(forDisplay: index)
        setMode(currentMode == .full ? .bsp : .full, forDisplay: index)
    }

    func setLayoutMode(_ mode: LayoutMode) {
        // Set layout on current display (for menu compatibility)
        setMode(mode, forDisplay: currentDisplayIndex)
    }

    func setLayoutModeForAllDisplays(_ mode: LayoutMode) {
        for i in 0..<NSScreen.screens.count {
            modePerDisplay[i] = mode
        }
        NotificationCenter.default.post(name: .layoutModeChanged, object: nil)
        retileAllScreens()
    }

    func retileAllScreens() {
        enforceLayout()
    }

    func getAllDisplayModes() -> [(index: Int, mode: LayoutMode)] {
        return NSScreen.screens.enumerated().map { (index, _) in
            (index: index, mode: getMode(forDisplay: index))
        }
    }

    // MARK: - Float Toggle

    func toggleFloatFocused() {
        guard let window = getFocusedWindow() else { return }
        let windowId = getWindowIdentifier(window)

        if manuallyFloatedWindows.contains(windowId) {
            // Unfloat - remove from set and retile
            manuallyFloatedWindows.remove(windowId)
        } else {
            // Float - add to set
            manuallyFloatedWindows.insert(windowId)
        }

        scheduleRetile()
    }

    private func getWindowIdentifier(_ window: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String) ?? ""

        return "\(pid):\(title.hashValue)"
    }

    private func isManuallyFloated(_ window: AXUIElement) -> Bool {
        return manuallyFloatedWindows.contains(getWindowIdentifier(window))
    }

    // MARK: - Maximize All

    func maximizeAllWindows(gap: Int) {
        enforceLayout()  // Retile all screens + update border
    }

    // MARK: - Cycle Windows

    func cycleWindows() {
        let screen = currentScreen
        // Include floating windows in cycle (they should be focusable, just not tiled)
        let windows = getWindowsOnScreen(screen, includeFloating: true)

        guard windows.count > 1 else { return }
        guard let focused = getFocusedWindow() else {
            if let first = windows.first, let app = getAppForWindow(first) {
                AXUIElementPerformAction(first, kAXRaiseAction as CFString)
                app.activate(options: [.activateIgnoringOtherApps])
                updateBorder()
            }
            return
        }

        var currentIndex = -1
        for (i, win) in windows.enumerated() {
            if isSameWindow(win, focused) {
                currentIndex = i
                break
            }
        }

        let nextIndex = (currentIndex == -1) ? 0 : (currentIndex + 1) % windows.count
        let nextWindow = windows[nextIndex]

        AXUIElementPerformAction(nextWindow, kAXRaiseAction as CFString)
        if let app = getAppForWindow(nextWindow) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        updateBorder()
    }

    // MARK: - Focus Display

    func focusDisplay(index: Int) {
        let screens = NSScreen.screens
        guard index < screens.count else { return }

        let targetScreen = screens[index]

        // If already on this display, toggle layout instead
        if currentDisplayIndex == index {
            let currentMode = getMode(forDisplay: index)
            let newMode: LayoutMode = currentMode == .full ? .bsp : .full
            setMode(newMode, forDisplay: index)
            return
        }

        saveCurrentFocus()

        if !restoreFocusOnScreen(targetScreen) {
            let windows = getWindowsOnScreen(targetScreen, includeFloating: true)
            if let firstWindow = windows.first, let app = getAppForWindow(firstWindow) {
                AXUIElementPerformAction(firstWindow, kAXRaiseAction as CFString)
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }

        moveMouse(to: targetScreen)
    }

    // MARK: - Retile Screen

    private func retileScreen(_ screen: NSScreen) {
        let windows = getWindowsOnScreen(screen)
        guard !windows.isEmpty else { return }

        let screenIndex = NSScreen.screens.firstIndex(of: screen) ?? 0
        let mode = getMode(forDisplay: screenIndex)

        let g = CGFloat(gap)
        let visibleFrame = screen.visibleFrame
        let axY = mainScreenHeight - visibleFrame.maxY

        let bounds = CGRect(
            x: visibleFrame.origin.x + g,
            y: axY + g,
            width: visibleFrame.width - 2 * g,
            height: visibleFrame.height - 2 * g
        )

        let frames: [CGRect]
        if mode == .full {
            frames = windows.map { _ in bounds }
        } else {
            frames = calculateMasterStackFrames(count: windows.count, bounds: bounds, gap: g)
        }

        for (i, window) in windows.enumerated() {
            setWindowFrame(window, frame: frames[i])
        }
    }

    private func calculateMasterStackFrames(count: Int, bounds: CGRect, gap: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }

        if count == 1 {
            return [bounds]
        }

        let masterWidth = (bounds.width - gap) / 2
        let stackWidth = bounds.width - gap - masterWidth

        var frames: [CGRect] = []

        frames.append(CGRect(
            x: bounds.origin.x,
            y: bounds.origin.y,
            width: masterWidth,
            height: bounds.height
        ))

        let stackCount = count - 1
        let stackHeight = (bounds.height - gap * CGFloat(stackCount - 1)) / CGFloat(stackCount)

        for i in 0..<stackCount {
            frames.append(CGRect(
                x: bounds.origin.x + masterWidth + gap,
                y: bounds.origin.y + CGFloat(i) * (stackHeight + gap),
                width: stackWidth,
                height: stackHeight
            ))
        }

        return frames
    }

    // MARK: - Helpers

    private func maximizeWindowOnScreen(_ window: AXUIElement, screen: NSScreen) {
        let g = CGFloat(gap)
        let visibleFrame = screen.visibleFrame
        let axY = mainScreenHeight - visibleFrame.maxY

        setWindowFrame(window, frame: CGRect(
            x: visibleFrame.origin.x + g,
            y: axY + g,
            width: visibleFrame.width - 2 * g,
            height: visibleFrame.height - 2 * g
        ))
    }

    private func unminimizeWindows(for app: NSRunningApplication) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }

        for window in windows {
            var minimizedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
               let minimized = minimizedRef as? Bool, minimized {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            }
        }
    }

    private func moveMouse(to screen: NSScreen) {
        let screenFrame = screen.frame
        CGWarpMouseCursorPosition(CGPoint(x: screenFrame.midX, y: mainScreenHeight - screenFrame.midY))
    }

    private func getWindowsOnScreen(_ screen: NSScreen, includeFloating: Bool = false) -> [AXUIElement] {
        refreshAppsCacheIfNeeded()
        var windows: [AXUIElement] = []

        for app in regularAppsCache {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let appWindows = windowsRef as? [AXUIElement] else { continue }

            for window in appWindows {
                guard isStandardWindow(window) else { continue }

                var minimizedRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
                   let minimized = minimizedRef as? Bool, minimized { continue }

                let frame = getWindowFrame(window)
                guard frame.width > 0 && frame.height > 0 else { continue }

                guard let windowScreen = screenContaining(axPoint: CGPoint(x: frame.midX, y: frame.midY)),
                      windowScreen == screen else { continue }

                if !includeFloating && shouldFloat(window: window, app: app) { continue }

                windows.append(window)
            }
        }
        return windows
    }

    private func getAppForWindow(_ window: AXUIElement) -> NSRunningApplication? {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        refreshAppsCacheIfNeeded()
        return pidToAppCache[pid]
    }

    private func isSameWindow(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
        var pidA: pid_t = 0, pidB: pid_t = 0
        AXUIElementGetPid(a, &pidA)
        AXUIElementGetPid(b, &pidB)
        if pidA != pidB { return false }

        // Compare by title for same-app windows (handles Brave profiles)
        var titleA: CFTypeRef?, titleB: CFTypeRef?
        AXUIElementCopyAttributeValue(a, kAXTitleAttribute as CFString, &titleA)
        AXUIElementCopyAttributeValue(b, kAXTitleAttribute as CFString, &titleB)
        return (titleA as? String) == (titleB as? String)
    }

    private func getFocusedWindow() -> AXUIElement? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success else { return nil }
        return (windowRef as! AXUIElement)
    }

    private func getWindowFrame(_ window: AXUIElement) -> CGRect {
        var positionRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success else { return .zero }

        var position = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    private func setWindowFrame(_ window: AXUIElement, frame: CGRect) {
        var position = frame.origin, size = frame.size
        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    private func screenContaining(axPoint: CGPoint) -> NSScreen? {
        let nsPoint = CGPoint(x: axPoint.x, y: mainScreenHeight - axPoint.y)
        for screen in NSScreen.screens {
            if screen.frame.contains(nsPoint) { return screen }
        }
        return NSScreen.main
    }

    private func isStandardWindow(_ window: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?, subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef)
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef)
        return (roleRef as? String) == (kAXWindowRole as String) &&
               (subroleRef as? String) == (kAXStandardWindowSubrole as String)
    }
}

// =============================================================================
// MARK: - Border Window
// =============================================================================

class BorderWindow: NSWindow {
    private let borderWidth: CGFloat = 3
    private let cornerRadius: CGFloat = 12
    private let borderColor = NSColor(red: 0.35, green: 0.68, blue: 0.35, alpha: 1.0)

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: .borderless, backing: .buffered, defer: false)
        setup()
    }

    convenience init() {
        self.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    }

    private func setup() {
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        hasShadow = false
        contentView = BorderView(borderWidth: borderWidth, borderColor: borderColor, cornerRadius: cornerRadius)
    }

    func show(around frame: CGRect, screenHeight: CGFloat) {
        let nsY = screenHeight - frame.origin.y - frame.height

        setFrame(CGRect(
            x: frame.origin.x - borderWidth,
            y: nsY - borderWidth,
            width: frame.width + 2 * borderWidth,
            height: frame.height + 2 * borderWidth
        ), display: true)
        orderFront(nil)
    }
}

class BorderView: NSView {
    private let borderWidth: CGFloat
    private let borderColor: NSColor
    private let cornerRadius: CGFloat

    init(borderWidth: CGFloat, borderColor: NSColor, cornerRadius: CGFloat) {
        self.borderWidth = borderWidth
        self.borderColor = borderColor
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        borderColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
                                 xRadius: cornerRadius, yRadius: cornerRadius)
        path.lineWidth = borderWidth
        path.stroke()
    }
}
