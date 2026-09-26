import AppKit
import MetalKit
#if SWIFT_PACKAGE
import LayoutCore
#endif

@MainActor
final class ParticleOverlay {
    let display: DesktopDisplay
    private let window: NSWindow
    private let scene: ParticleScene
    private let view: MTKView
    private let windowTracker: WindowGeometryTracker
    private var windowRevision: UInt64?
    private var outlines: CAShapeLayer?
    private var cursorOutline: CAShapeLayer?
    private var outlineWindow: NSWindow?
    private var collisionBordersVisible = false
    private var outlineRevision: UInt64?
    private var cannon: DesktopCannon?
    private var cursorCollisionsEnabled: Bool
    private let accelerometer: Accelerometer

    init(screen: NSScreen, count: Int, windowTracker: WindowGeometryTracker, accelerometer: Accelerometer,
         collisionBordersVisible: Bool = false,
         cursorCollisionsEnabled: Bool = false,
         cannonMode: Bool = false, fireRate: Int = 24, ballRadius: CGFloat = 1.5,
         ballSpeed: CGFloat = ParticleEngine.defaultMaximumSpeed) throws {
        self.windowTracker = windowTracker
        self.accelerometer = accelerometer
        self.cursorCollisionsEnabled = cursorCollisionsEnabled
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! UInt32
        display = DesktopDisplay(id: number, name: screen.localizedName, frame: CGDisplayBounds(number))
        window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                               backing: .buffered, defer: false, screen: screen)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = false
        // Keep particles above the desktop but below ordinary application windows.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        // Let AppKit keep this window on the Space where it is first ordered.
        window.collectionBehavior = [.stationary, .fullScreenNone, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.hidesOnDeactivate = false
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        scene = try ParticleScene(engine: cannonMode
            ? .cannon(bounds: bounds, radius: ballRadius)
            : .rain(count: count, bounds: bounds, seed: UInt64(number), radius: ballRadius))
        scene.engine.maximumSpeed = ballSpeed
        view = scene.makeView(size: screen.frame.size)
        window.contentView = view
        view.isPaused = true
        scene.beforeFrame = { [weak self] time in
            guard let self else { return false }
            // Check before reading geometry or encoding physics, including frames
            // delivered before the active-Space notification reaches the delegate.
            guard self.isOnActiveSpace else {
                self.pause()
                return false
            }
            let snapshot = self.windowTracker.snapshot
            guard snapshot.stableDisplays.contains(self.display.id) else {
                // Keep the render timer alive: a cancelled swipe sends no Space
                // change notification. It must resume automatically once settled.
                self.scene.engine.resetClock()
                self.clearCursor()
                self.cannon?.resetClock()
                return false
            }
            guard !self.view.isPaused else { return false }
            let motion = self.accelerometer.acceleration(at: time)
            let strength = abs(self.scene.engine.gravity)
            self.scene.engine.externalAcceleration = CGVector(dx: motion.dx * strength, dy: motion.dy * strength)
            self.updateCursor()
            self.updateObstacles(at: time, snapshot: snapshot)
            self.cannon?.advance(at: time)
            return true
        }
        // Bind the empty, paused overlay now, before the asynchronous Finder scan.
        // A Space switch during that scan must not move the initial shower.
        window.orderFrontRegardless()
        if cannonMode { cannon = DesktopCannon(parent: window, engine: scene.engine, fireRate: fireRate) }
        setCollisionBordersVisible(collisionBordersVisible)
    }

    func setFireRate(_ rate: Int) { cannon?.fireRate = rate }
    func setBallSpeed(_ speed: CGFloat) { scene.engine.maximumSpeed = speed }

    func setCursorCollisionsEnabled(_ enabled: Bool) {
        cursorCollisionsEnabled = enabled
        clearCursor()
    }

    private func clearCursor() {
        scene.engine.cursorPosition = nil
        cursorOutline?.isHidden = true
    }

    private func updateCursor() {
        guard cursorCollisionsEnabled else { return }
        // Poll once per displayed frame; the overlay still passes every click through.
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        scene.engine.cursorPosition = scene.engine.bounds.contains(point) ? point : nil
        guard collisionBordersVisible, let cursorOutline else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorOutline.isHidden = scene.engine.cursorPosition == nil
        cursorOutline.position = point
        CATransaction.commit()
    }

    var isOnActiveSpace: Bool { window.isOnActiveSpace }
    var spaceAnchor: WindowGeometry.Anchor {
        WindowGeometry.Anchor(windowID: CGWindowID(window.windowNumber), displayID: display.id, frame: display.frame)
    }

    func setCollisionBordersVisible(_ visible: Bool) {
        collisionBordersVisible = visible
        // Defer creating/ordering diagnostics until their owning Space is active.
        guard isOnActiveSpace else {
            outlineWindow?.orderOut(nil)
            return
        }
        if visible, outlineWindow == nil {
            // Keep diagnostics above apps while particles remain below them.
            let borderWindow = OverlayWindow(contentRect: window.frame, styleMask: .borderless,
                                             backing: .buffered, defer: false, screen: window.screen)
            borderWindow.backgroundColor = .clear
            borderWindow.isOpaque = false
            borderWindow.hasShadow = false
            borderWindow.ignoresMouseEvents = true
            borderWindow.level = .floating
            borderWindow.collectionBehavior = window.collectionBehavior
            borderWindow.isReleasedWhenClosed = false
            borderWindow.isExcludedFromWindowsMenu = true
            borderWindow.hidesOnDeactivate = false
            let borderView = NSView(frame: CGRect(origin: .zero, size: window.frame.size))
            borderView.wantsLayer = true
            let outlines = CAShapeLayer()
            outlines.strokeColor = NSColor.systemRed.cgColor
            outlines.fillColor = nil
            outlines.lineWidth = 1.5
            borderView.layer?.addSublayer(outlines)
            let cursorOutline = CAShapeLayer()
            cursorOutline.strokeColor = outlines.strokeColor
            cursorOutline.fillColor = nil
            cursorOutline.lineWidth = outlines.lineWidth
            let radius = ParticleEngine.cursorRadius
            cursorOutline.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius), transform: nil)
            cursorOutline.isHidden = true
            borderView.layer?.addSublayer(cursorOutline)
            self.cursorOutline = cursorOutline
            borderWindow.contentView = borderView
            self.outlines = outlines
            outlineWindow = borderWindow
        }
        if visible {
            outlineRevision = nil
            updateOutlines()
            if window.isVisible { outlineWindow?.orderFrontRegardless() }
        } else {
            outlineWindow?.orderOut(nil)
        }
    }

    private var desktopObstacles: [CollisionShape] = []
    private var staticObstacles: [CollisionShape] = []
    private let dockTracker = DockGeometryTracker()
    private var nextGeometryUpdate: Double = 0

    private func updateObstacles(at time: Double, snapshot: WindowGeometryTracker.Snapshot) {
        defer { updateOutlines() }
        if windowRevision != snapshot.revision {
            scene.engine.windowObstacles = WindowGeometry.localRectangles(snapshot.rectangles, on: display.frame)
            windowRevision = snapshot.revision
        }
        if time >= nextGeometryUpdate {
            nextGeometryUpdate = time + 0.1
            staticObstacles = desktopObstacles
            if let screen = window.screen, let dock = dockTracker.geometry(on: screen, at: time) {
                let rect = dock.rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                staticObstacles.append(DockGeometry.collisionShape(in: rect))
            }
        }
        cannon?.setObstacles(staticObstacles, windows: scene.engine.windowObstacles)
        scene.engine.collisionShapes = staticObstacles + (cannon?.collisionShapes ?? [])
    }

    private func updateOutlines() {
        guard collisionBordersVisible, let outlines, outlineRevision != scene.engine.geometryRevision else { return }
        outlineRevision = scene.engine.geometryRevision
        let path = CGMutablePath()
        for shape in scene.engine.collisionShapes { path.addPath(shape.path) }
        for rect in scene.engine.windowObstacles {
            let radius = rect.contains(scene.engine.bounds) ? 0 : scene.engine.windowCornerRadius
            path.addPath(WindowCornerCurve.path(in: rect, radius: radius))
        }
        let bounds = scene.engine.bounds.insetBy(dx: outlines.lineWidth / 2, dy: outlines.lineWidth / 2)
        path.move(to: CGPoint(x: bounds.minX, y: bounds.maxY))
        path.addLine(to: CGPoint(x: bounds.minX, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outlines.path = path
        CATransaction.commit()
    }

    func setItems(_ items: [DesktopItem]) {
        guard isOnActiveSpace, windowTracker.snapshot.stableDisplays.contains(display.id) else { return }
        desktopObstacles = items.compactMap { $0.collisionShape(on: display.frame) }
        nextGeometryUpdate = 0
        if view.isPaused {
            scene.engine.resetClock()
            view.isPaused = false
            setCollisionBordersVisible(collisionBordersVisible)
        }
    }

    func pause() {
        view.isPaused = true
        clearCursor()
        scene.engine.resetClock()
        cannon?.resetClock()
        dockTracker.invalidate()
        windowRevision = nil
        nextGeometryUpdate = 0
    }

    func close() {
        // Hide before disconnecting the renderer.
        cannon?.close()
        cannon = nil
        outlineWindow?.orderOut(nil)
        outlineWindow?.close()
        outlineWindow = nil
        window.orderOut(nil)
        view.isPaused = true
        view.delegate = nil
        window.close()
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
