import AppKit
#if SWIFT_PACKAGE
import LayoutCore
#endif

/// A menu-bar toggle controls the click-through desktop particle overlay.
@MainActor
final class ParticlesDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let defaultBallCount = 10_000
    private static let ballCountDefaultsKey = "ballCount"
    private static let defaultFireRate = 25
    private static let ballCounts = [5_000, 10_000, 15_000, 20_000, 25_000, 50_000, 100_000]
    private static let ballSpeeds = Array(stride(from: 200, through: 400, by: 50))
    private static let fireRates = Array(stride(from: 10, through: 40, by: 5))
    private enum BallSize: Double, CaseIterable {
        case small = 1.5, medium = 3, large = 4.5

        var title: String {
            switch self {
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            }
        }

        var maximumBallCount: Int {
            switch self {
            case .small: 100_000
            case .medium: 50_000
            case .large: 25_000
            }
        }
    }
    private var ballSize = BallSize(rawValue: UserDefaults.standard.double(forKey: "ballRadius")) ?? .small
    private var ballSpeed = savedOption(forKey: "ballSpeed", options: ballSpeeds,
                                       default: Int(ParticleEngine.defaultMaximumSpeed))
    private var cannonMode = CommandLine.arguments.contains("--cannon") || UserDefaults.standard.bool(forKey: "cannonMode")
    private var fireRate = savedOption(forKey: "cannonFireRate", options: fireRates, default: defaultFireRate)
    private var cursorCollisionsEnabled = UserDefaults.standard.bool(forKey: "cursorCollisions")
    private var accelerometerEnabled = UserDefaults.standard.bool(forKey: "accelerometer")
    private let accelerometer = Accelerometer()
    private weak var accelerometerMenuItem: NSMenuItem?

    private struct DisplayConfiguration: Equatable {
        let id: UInt32
        let frame: CGRect
        let scale: CGFloat
    }

    private let reader = DesktopReader()
    private let windowTracker = WindowGeometryTracker()
    private var overlays: [ParticleOverlay] = []
    private var refreshTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var permissionsPrepared = false
    private var generation = 0
    private var lastStatus = ""
    private var ballsEnabled = CommandLine.arguments.contains("--cannon")
    private var collisionBordersVisible = CommandLine.arguments.contains("--collision-borders-only")
    private let debugEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return CommandLine.arguments.contains("--debug") || CommandLine.arguments.contains("--collision-borders-only")
        #endif
    }()
    private var ballCount = savedOption(forKey: ballCountDefaultsKey, options: ballCounts, default: defaultBallCount)
    private var statusItem: NSStatusItem?
    private var displayConfiguration: [DisplayConfiguration] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        limitBallCountForSize()
        installStatusItem()
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshSpace),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshSpace),
            name: NSWorkspace.didWakeNotification, object: nil)
        permissionTask = Task { [weak self] in
            guard let self else { return }
            let status = await reader.preparePermissions()
            guard !Task.isCancelled else { return }
            for message in status { NSLog("Particles: %@", message) }
            permissionsPrepared = true
            permissionTask = nil
            rebuildDisplays()
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.menu = makeStatusMenu()
        updateStatusItem()
    }

    private func updateStatusItem() {
        let action = toggleTitle
        let image = NSImage(systemSymbolName: "circle", accessibilityDescription: action)
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = action
        statusItem?.button?.setAccessibilityLabel(action)
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let mode = NSMenuItem(title: "Simulation mode", action: nil, keyEquivalent: "")
        let modeControl = NSSegmentedControl(labels: ["Cannon", "Waterfall"], trackingMode: .selectOne,
                                            target: self, action: #selector(changeMode(_:)))
        modeControl.segmentStyle = .rounded
        modeControl.selectedSegment = cannonMode ? 0 : 1
        modeControl.setAccessibilityLabel("Simulation mode")
        modeControl.sizeToFit()
        let modeView = NSView(frame: NSRect(x: 0, y: 0, width: modeControl.frame.width + 32,
                                           height: modeControl.frame.height + 12))
        modeControl.frame.origin = NSPoint(x: 16, y: 6)
        modeControl.autoresizingMask = [.width]
        modeView.addSubview(modeControl)
        mode.view = modeView
        menu.addItem(mode)

        let toggle = menu.addItem(withTitle: toggleTitle,
                                  action: #selector(toggleBalls), keyEquivalent: "")
        toggle.target = self
        menu.addItem(.separator())

        let countTitle = cannonMode ? "Fire rate" : "Balls"
        let countItem = menu.addItem(withTitle: countTitle, action: nil, keyEquivalent: "")
        countItem.isEnabled = cannonMode || !ballsEnabled
        let countMenu = NSMenu(title: countTitle)
        countMenu.autoenablesItems = false
        for value in cannonMode ? Self.fireRates : Self.ballCounts {
            let title = cannonMode ? "\(value) balls/sec" : "\(value / 1_000) 000"
            let option = countMenu.addItem(withTitle: title,
                                          action: cannonMode ? #selector(changeFireRate(_:)) : #selector(changeBallCount(_:)),
                                          keyEquivalent: "")
            option.target = self
            option.tag = value
            option.state = value == (cannonMode ? fireRate : ballCount) ? .on : .off
            if !cannonMode { option.isEnabled = value <= ballSize.maximumBallCount }
        }
        countItem.submenu = countMenu

        menu.addItem(.separator())
        let sizeItem = menu.addItem(withTitle: "Ball size", action: nil, keyEquivalent: "")
        sizeItem.isEnabled = !ballsEnabled
        let sizeMenu = NSMenu(title: "Ball size")
        for (index, size) in BallSize.allCases.enumerated() {
            let option = sizeMenu.addItem(withTitle: size.title, action: #selector(changeBallSize(_:)), keyEquivalent: "")
            option.target = self
            option.tag = index
            option.state = ballSize == size ? .on : .off
        }
        sizeItem.submenu = sizeMenu

        let speedItem = menu.addItem(withTitle: "Ball speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu(title: "Ball speed")
        for speed in Self.ballSpeeds {
            let option = speedMenu.addItem(withTitle: "\(speed) points/sec", action: #selector(changeBallSpeed(_:)), keyEquivalent: "")
            option.target = self
            option.tag = speed
            option.state = ballSpeed == speed ? .on : .off
        }
        speedItem.submenu = speedMenu

        if debugEnabled {
            menu.addItem(.separator())
            let borders = menu.addItem(withTitle: "Show collision borders",
                                       action: #selector(toggleCollisionBorders), keyEquivalent: "")
            borders.target = self
            borders.state = collisionBordersVisible ? .on : .off
        }

        menu.addItem(.separator())
        let cursor = menu.addItem(withTitle: "Cursor collisions", action: #selector(toggleCursorCollisions), keyEquivalent: "")
        cursor.target = self
        cursor.state = cursorCollisionsEnabled ? .on : .off
        let motion = menu.addItem(withTitle: "Accelerometer", action: #selector(toggleAccelerometer), keyEquivalent: "")
        motion.target = self
        accelerometerMenuItem = motion
        updateAccelerometerMenuItem()
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        modeView.setFrameSize(NSSize(width: menu.size.width, height: modeView.frame.height))
        return menu
    }

    private var toggleTitle: String {
        if cannonMode { return ballsEnabled ? "Remove cannon" : "Spawn cannon" }
        return ballsEnabled ? "Remove balls" : "Spawn balls"
    }

    @objc private func changeMode(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment == 0 || sender.selectedSegment == 1 else { return }
        let selectedCannonMode = sender.selectedSegment == 0
        guard selectedCannonMode != cannonMode else { return }
        statusItem?.menu?.cancelTracking()
        cannonMode = selectedCannonMode
        UserDefaults.standard.set(cannonMode, forKey: "cannonMode")
        ballsEnabled = false
        updateStatusItem()
        statusItem?.menu = makeStatusMenu()
        rebuildDisplays()
    }

    @objc private func changeFireRate(_ sender: NSMenuItem) {
        guard Self.fireRates.contains(sender.tag) else { return }
        fireRate = sender.tag
        UserDefaults.standard.set(fireRate, forKey: "cannonFireRate")
        overlays.forEach { $0.setFireRate(fireRate) }
        statusItem?.menu = makeStatusMenu()
    }

    @objc private func changeBallSize(_ sender: NSMenuItem) {
        guard !ballsEnabled else { return }
        guard BallSize.allCases.indices.contains(sender.tag) else { return }
        let size = BallSize.allCases[sender.tag]
        guard size != ballSize else { return }
        ballSize = size
        UserDefaults.standard.set(size.rawValue, forKey: "ballRadius")
        limitBallCountForSize()
        statusItem?.menu = makeStatusMenu()
        rebuildDisplays()
    }

    @objc private func changeBallSpeed(_ sender: NSMenuItem) {
        guard Self.ballSpeeds.contains(sender.tag) else { return }
        ballSpeed = sender.tag
        UserDefaults.standard.set(ballSpeed, forKey: "ballSpeed")
        overlays.forEach { $0.setBallSpeed(CGFloat(ballSpeed)) }
        statusItem?.menu = makeStatusMenu()
    }

    @objc private func toggleBalls() {
        ballsEnabled.toggle()
        updateStatusItem()
        statusItem?.menu = makeStatusMenu()
        rebuildDisplays()
    }

    @objc private func toggleCursorCollisions() {
        cursorCollisionsEnabled.toggle()
        UserDefaults.standard.set(cursorCollisionsEnabled, forKey: "cursorCollisions")
        overlays.forEach { $0.setCursorCollisionsEnabled(cursorCollisionsEnabled) }
        statusItem?.menu = makeStatusMenu()
    }

    @objc private func toggleAccelerometer() {
        accelerometerEnabled.toggle()
        UserDefaults.standard.set(accelerometerEnabled, forKey: "accelerometer")
        updateAccelerometer()
        updateAccelerometerMenuItem()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateAccelerometerMenuItem()
    }

    private func updateAccelerometerMenuItem() {
        let failure = accelerometerEnabled ? accelerometer.failure : nil
        accelerometerMenuItem?.title = failure == nil ? "Accelerometer" : "Accelerometer (unavailable)"
        accelerometerMenuItem?.state = accelerometerEnabled ? (failure == nil ? .on : .mixed) : .off
        accelerometerMenuItem?.toolTip = failure ?? "Tilt or gently shake your MacBook to move the balls. Requires a supported built-in sensor."
    }

    private func updateAccelerometer() {
        if accelerometerEnabled && ballsEnabled && overlays.contains(where: { $0.isOnActiveSpace }) {
            accelerometer.start()
        } else {
            accelerometer.stop()
        }
    }

    @objc private func toggleCollisionBorders() {
        collisionBordersVisible.toggle()
        statusItem?.menu = makeStatusMenu()
        if overlays.isEmpty || (!ballsEnabled && !collisionBordersVisible) {
            rebuildDisplays()
        } else {
            overlays.forEach { $0.setCollisionBordersVisible(collisionBordersVisible) }
        }
    }

    @objc private func changeBallCount(_ sender: NSMenuItem) {
        guard !ballsEnabled else { return }
        guard Self.ballCounts.contains(sender.tag), sender.tag <= ballSize.maximumBallCount else { return }
        ballCount = sender.tag
        UserDefaults.standard.set(ballCount, forKey: Self.ballCountDefaultsKey)
        statusItem?.menu = makeStatusMenu()
    }

    private func limitBallCountForSize() {
        let allowedCount = min(ballCount, ballSize.maximumBallCount)
        guard allowedCount != ballCount else { return }
        ballCount = allowedCount
        UserDefaults.standard.set(ballCount, forKey: Self.ballCountDefaultsKey)
    }

    private static func savedOption(forKey key: String, options: [Int], default defaultValue: Int) -> Int {
        guard let saved = UserDefaults.standard.object(forKey: key) as? Int else { return defaultValue }
        return options.min { abs(Double($0) - Double(saved)) < abs(Double($1) - Double(saved)) } ?? defaultValue
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func stopSimulation() {
        accelerometer.stop()
        windowTracker.stop()
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        overlays.forEach { $0.close() }
        overlays.removeAll()
    }

    /// AppKit also sends this notification when the Dock changes its visible
    /// frame. Only recreate overlay windows when the actual display layout has
    /// changed; Dock geometry is updated in-place by DockGeometryTracker.
    @objc private func screenParametersChanged() {
        guard currentDisplayConfiguration() != displayConfiguration else { return }
        rebuildDisplays()
    }

    private func currentDisplayConfiguration() -> [DisplayConfiguration] {
        // NSScreen ordering can change with keyboard focus, without a layout change.
        NSScreen.screens.map { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! UInt32
            return DisplayConfiguration(id: id, frame: screen.frame, scale: screen.backingScaleFactor)
        }.sorted { $0.id < $1.id }
    }

    @objc private func rebuildDisplays() {
        stopSimulation()
        displayConfiguration = currentDisplayConfiguration()
        // A toggle during a system prompt takes effect after both requests finish.
        guard permissionsPrepared else { return }
        guard ballsEnabled || collisionBordersVisible else { return }
        let screens = NSScreen.screens
        let totalWidth = screens.reduce(CGFloat.zero) { $0 + $1.frame.width }
        guard totalWidth > 0 else { return }
        let totalCount = ballsEnabled ? LaunchArguments.value("--count", default: ballCount) : 0
        var remaining = totalCount
        for (index, screen) in screens.enumerated() {
            let count = index == screens.count - 1 ? remaining : Int(CGFloat(totalCount) * screen.frame.width / totalWidth)
            remaining -= count
            do { overlays.append(try ParticleOverlay(screen: screen, count: count, windowTracker: windowTracker,
                                                    accelerometer: accelerometer,
                                                    collisionBordersVisible: collisionBordersVisible,
                                                    cursorCollisionsEnabled: cursorCollisionsEnabled,
                                                    cannonMode: cannonMode && ballsEnabled, fireRate: fireRate,
                                                    ballRadius: CGFloat(ballSize.rawValue), ballSpeed: CGFloat(ballSpeed))) }
            catch { NSLog("Metal overlay could not start: %@", error.localizedDescription) }
        }
        startRefreshing()
    }

    @objc private func willSleep() {
        accelerometer.stop()
        windowTracker.stop()
        refreshTask?.cancel()
        overlays.forEach { $0.pause() }
    }

    @objc private func refreshSpace() {
        // Preserve each shower on its original Space. Only active overlays resume
        // after fresh geometry arrives; reset timing so time away is not simulated.
        overlays.forEach { $0.pause() }
        startRefreshing()
    }

    private func startRefreshing() {
        refreshTask?.cancel()
        windowTracker.stop()
        updateAccelerometer()
        guard ballsEnabled || collisionBordersVisible,
              overlays.contains(where: { $0.isOnActiveSpace }) else { return }
        windowTracker.start(anchors: overlays.map(\.spaceAnchor))
        let generation = generation
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let scanSnapshot = self.windowTracker.snapshot
                let activeOverlays = self.overlays.filter {
                    $0.isOnActiveSpace && scanSnapshot.stableDisplays.contains($0.display.id)
                }
                if activeOverlays.isEmpty {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    continue
                }
                let displays = activeOverlays.map(\.display)
                let result = await self.reader.scan(displays: displays, anchors: activeOverlays.map(\.spaceAnchor),
                                                    readItems: true)
                guard !Task.isCancelled, generation == self.generation else { return }
                // Discard a Finder/widget scan that straddled a transition, even
                // if the gesture was cancelled and we are back on the same Space.
                if scanSnapshot.spaceRevision == self.windowTracker.snapshot.spaceRevision {
                    for overlay in activeOverlays where result.stationaryDisplays.contains(overlay.display.id) {
                        overlay.setItems(result.items)
                    }
                }
                let status = result.finderStatus + " " + result.widgetStatus
                if status != self.lastStatus {
                    NSLog("Particles: %@", status)
                    self.lastStatus = status
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTask?.cancel()
        stopSimulation()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
}
