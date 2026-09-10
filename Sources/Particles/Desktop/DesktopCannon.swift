import AppKit
#if SWIFT_PACKAGE
import LayoutCore
#endif

/// A small nonactivating input window leaves the rest of the desktop clickable.
/// Its visible parts also supply the ball solver's collision polygons.
@MainActor
final class DesktopCannon {
    private let panel: CannonPanel
    private let drawing: CannonView
    private let engine: ParticleEngine
    private let ballRadius: CGFloat
    private let screenOrigin: CGPoint
    private let placement: CannonPlacement
    private var origin: CGPoint { placement.origin }
    private var angle: CGFloat { placement.angle }
    private var previousTime: Double?
    private var untilShot = 0.0
    private var animationTime = 0.0
    private enum DragMode {
        case move(offset: CGPoint)
        case aim(pointerAngle: CGFloat)
    }
    private var dragMode: DragMode?
    var fireRate: Int = 24 {
        didSet { untilShot = min(untilShot, 1 / Double(max(1, fireRate))) }
    }

    init(parent: NSWindow, engine: ParticleEngine, fireRate: Int) {
        self.engine = engine
        ballRadius = engine.particles.first?.radius ?? 1.5
        self.fireRate = fireRate
        screenOrigin = parent.frame.origin
        placement = CannonPlacement(bounds: engine.bounds)
        drawing = CannonView(frame: CGRect(origin: .zero, size: CannonGeometry.viewSize))
        panel = CannonPanel(contentRect: drawing.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = parent.level
        panel.collectionBehavior = parent.collectionBehavior
        panel.contentView = drawing
        panel.ignoresMouseEvents = true
        parent.addChildWindow(panel, ordered: .above)
        panel.orderOut(nil)
        drawing.toolTip = "Drag wheel to move · Drag barrel to aim · Scroll to aim"
        drawing.setAccessibilityElement(true)
        drawing.setAccessibilityLabel("Ball cannon")
        drawing.setAccessibilityHelp("Drag the wheel to move. Drag the barrel or scroll to aim. Change fire rate in the menu bar.")
        drawing.drag = { [weak self] phase in self?.drag(phase) }
        drawing.aim = { [weak self] delta in self?.aim(delta) }
        updateDrawing()
    }

    var collisionShapes: [CollisionShape] { placement.collisionShapes }

    func setObstacles(_ shapes: [CollisionShape], windows: [CGRect]) {
        let oldOrigin = origin
        let wasPlaced = placement.isPlaced
        placement.updateObstacles(shapes, windows: windows, cornerRadius: engine.windowCornerRadius)
        if placement.isPlaced {
            if !wasPlaced || origin != oldOrigin { updateDrawing() }
        } else if wasPlaced || panel.isVisible {
            panel.orderOut(nil)
            resetClock()
        }
    }

    func advance(at time: Double) {
        guard placement.isPlaced else { resetClock(); return }
        let elapsed = min(1.0 / 30, max(0, time - (previousTime ?? time)))
        previousTime = time
        animationTime += elapsed
        untilShot -= elapsed
        // A stalled frame never releases a catch-up burst.
        var shots = 0
        while untilShot <= 0, shots < 4 {
            let direction = angle + sin(animationTime * 2.1) * 0.12 + CGFloat.random(in: -0.19...0.19)
            let spread = CGFloat.random(in: -1...1) * max(0, CannonGeometry.muzzleHalfWidth - ballRadius)
            // Place the ball's near edge directly against the muzzle lip.
            let localMuzzle = CannonGeometry.point(along: CannonGeometry.muzzleDistance + ballRadius,
                                                  across: spread, angle: angle)
            let muzzle = CGPoint(x: origin.x + localMuzzle.x, y: origin.y + localMuzzle.y)
            let clearance = ballRadius + 0.5
            if engine.bounds.insetBy(dx: clearance, dy: clearance).contains(muzzle),
               !placement.obstacles.contains(where: { $0.intersectsCircle(at: muzzle, radius: clearance) }) {
                let speed = engine.maximumSpeed * CGFloat.random(in: 0.85...1)
                engine.emit(position: muzzle, velocity: CGVector(dx: cos(direction) * speed, dy: sin(direction) * speed))
            }
            untilShot += Double.random(in: 0.7...1.3) / Double(max(1, fireRate))
            shots += 1
        }
        untilShot = max(0, untilShot)
        let mouse = NSEvent.mouseLocation
        let local = CGPoint(x: mouse.x - screenOrigin.x - origin.x, y: mouse.y - screenOrigin.y - origin.y)
        panel.ignoresMouseEvents = dragMode == nil && drawing.part(at: local) == nil
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func drag(_ phase: CannonView.DragPhase) {
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x - screenOrigin.x, y: mouse.y - screenOrigin.y)
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        switch phase {
        case .began:
            guard placement.isPlaced, let part = drawing.part(at: local) else { return }
            switch part {
            case .wheel: dragMode = .move(offset: local)
            case .barrel:
                dragMode = .aim(pointerAngle: atan2(local.y - CannonGeometry.pivot.y, local.x - CannonGeometry.pivot.x))
            }
            panel.ignoresMouseEvents = false
            NSCursor.closedHand.set()
        case .moved:
            guard placement.isPlaced, let dragMode else { return }
            switch dragMode {
            case .aim(let previousAngle):
                let dx = local.x - CannonGeometry.pivot.x, dy = local.y - CannonGeometry.pivot.y
                guard hypot(dx, dy) > 6 else { return }
                let pointerAngle = atan2(dy, dx)
                rotate(by: atan2(sin(pointerAngle - previousAngle), cos(pointerAngle - previousAngle)))
                self.dragMode = .aim(pointerAngle: pointerAngle)
            case .move(let dragOffset):
                let target = CGPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y)
                let dx = target.x - origin.x, dy = target.y - origin.y
                let steps = max(1, Int(ceil(hypot(dx, dy) / 2)))
                // Sweep in small increments so dragging cannot cross a thin icon.
                for _ in 0..<min(steps, 2_000) {
                    let next = CGPoint(x: origin.x + dx / CGFloat(steps), y: origin.y + dy / CGFloat(steps))
                    if !placement.move(to: next) {
                        let horizontal = CGPoint(x: next.x, y: origin.y)
                        placement.move(to: horizontal)
                        let vertical = CGPoint(x: origin.x, y: next.y)
                        placement.move(to: vertical)
                    }
                }
                updateDrawing()
            }
        case .ended:
            dragMode = nil
            NSCursor.openHand.set()
        }
    }

    private func aim(_ delta: CGFloat) {
        guard dragMode == nil else { return }
        rotate(by: delta * 0.025)
    }

    private func rotate(by delta: CGFloat) {
        guard placement.isPlaced, delta.isFinite else { return }
        let travel = max(-CGFloat.pi, min(CGFloat.pi, delta))
        let steps = max(1, Int(ceil(abs(travel) * CannonGeometry.muzzleDistance / 2)))
        // Sweep the barrel, so aiming cannot tunnel through an icon or window.
        for _ in 0..<steps {
            let proposed = angle + travel / CGFloat(steps)
            guard placement.aim(to: atan2(sin(proposed), cos(proposed))) else { break }
        }
        updateDrawing()
    }

    private func updateDrawing() {
        drawing.angle = angle
        drawing.shapes = placement.localShapes
        drawing.needsDisplay = true
        panel.setFrameOrigin(CGPoint(x: screenOrigin.x + origin.x, y: screenOrigin.y + origin.y))
        panel.invalidateCursorRects(for: drawing)
    }

    func resetClock() {
        previousTime = nil
        untilShot = 0
        dragMode = nil
        panel.ignoresMouseEvents = true
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.close()
    }
}

private final class CannonPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CannonView: NSView {
    enum DragPhase { case began, moved, ended }
    enum Part { case wheel, barrel }
    var drag: ((DragPhase) -> Void)?
    var aim: ((CGFloat) -> Void)?
    var angle: CGFloat = .pi * 0.31
    var shapes: [CollisionShape] = []
    private static let wheel = sprite(named: "CannonWheel", crop: CannonGeometry.wheelCrop)
    private static let barrel = sprite(named: "CannonBarrel", crop: CannonGeometry.barrelCrop)

    private static func sprite(named name: String, crop: CGRect) -> CGImage {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url),
              let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = bitmap.cropping(to: crop) else {
            preconditionFailure("Missing cannon sprite: \(name)")
        }
        return cropped
    }

    func part(at point: CGPoint) -> Part? {
        // The foreground wheel owns the overlap, including the spoke gaps.
        if hypot(point.x - CannonGeometry.pivot.x, point.y - CannonGeometry.pivot.y) <= CannonGeometry.wheelRadius {
            return .wheel
        }
        if shapes.first?.contains(point) == true { return .barrel }
        return nil
    }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { drag?(.began) }
    override func mouseDragged(with event: NSEvent) { drag?(.moved) }
    override func mouseUp(with event: NSEvent) { drag?(.ended) }
    override func scrollWheel(with event: NSEvent) { aim?(event.scrollingDeltaY) }
    override func resetCursorRects() {
        for shape in shapes { addCursorRect(shape.bounds, cursor: .openHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.saveGState()
        context.translateBy(x: CannonGeometry.pivot.x, y: CannonGeometry.pivot.y)
        context.rotate(by: angle - .pi / 2)
        context.draw(Self.barrel, in: CannonGeometry.barrelRect)
        context.restoreGState()
        context.draw(Self.wheel, in: CannonGeometry.wheelRect)
    }
}
