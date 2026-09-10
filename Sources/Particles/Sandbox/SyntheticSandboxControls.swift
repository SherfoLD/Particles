import AppKit
#if SWIFT_PACKAGE
import LayoutCore
#endif

/// Input lives above the Metal view; source objects remain draggable even while
/// their delayed collision samples are still at an earlier position.
@MainActor
final class SyntheticCanvas: NSView {
    let world: SyntheticWorld
    var selected: String? { didSet { needsDisplay = true } }
    var onSelection: ((String?) -> Void)?
    var onMove: (() -> Void)?
    private var dragOffset = CGPoint.zero
    private var sourcePaths: [String: (CGRect, CGPath)] = [:]
    init(world: SyntheticWorld, frame: CGRect) { self.world = world; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for obstacle in world.obstacles {
            let id = obstacle.spec.id
            if let frame = obstacle.frame(at: world.time) {
                if sourcePaths[id]?.0 != frame { sourcePaths[id] = (frame, world.registry.geometry(type: obstacle.spec.type, frame: frame).path) }
                context.addPath(sourcePaths[id]!.1)
                context.setFillColor(NSColor.systemTeal.withAlphaComponent(0.17).cgColor)
                context.setStrokeColor((id == selected ? NSColor.white : NSColor.systemTeal).cgColor)
                context.setLineWidth(id == selected ? 2 : 1)
                context.setLineDash(phase: 0, lengths: [])
                context.drawPath(using: .fillStroke)
                (id as NSString).draw(at: CGPoint(x: frame.minX + 5, y: frame.maxY + 4), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            }
            if obstacle.delivered?.frame != nil, let geometry = obstacle.geometry {
                context.addPath(geometry.path)
                context.setLineWidth(1.5)
                context.setStrokeColor(NSColor.systemOrange.cgColor)
                context.setLineDash(phase: 0, lengths: [5, 3]); context.strokePath()
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        selected = world.obstacles.reversed().first { $0.frame(at: world.time)?.contains(point) == true }?.spec.id
        if let obstacle = world.obstacles.first(where: { $0.spec.id == selected }), let frame = obstacle.frame(at: world.time) {
            dragOffset = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        }
        window?.makeFirstResponder(self); onSelection?(selected)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let selected, let obstacle = world.obstacles.first(where: { $0.spec.id == selected }),
              var frame = obstacle.frame(at: world.time) else { return }
        let point = convert(event.locationInWindow, from: nil)
        frame.origin = CGPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y)
        onMove?(); world.move(id: selected, to: frame); needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            if let selected { world.remove(id: selected) }
            selected = nil; onSelection?(nil)
        } else { super.keyDown(with: event) }
    }
}

@MainActor
final class SyntheticSandboxControls: NSObject {
    let world: SyntheticWorld
    let canvas: SyntheticCanvas
    let view: NSView
    let status = NSTextField(wrappingLabelWithString: "")
    private let type = NSPopUpButton()
    private let objects = NSPopUpButton()
    private let hz = NSTextField(string: "60")
    private let delay = NSTextField(string: "0")
    private let width = NSTextField(string: "320")
    private let height = NSTextField(string: "200")
    private let selection = NSTextField(wrappingLabelWithString: "No obstacle selected")
    private let message = NSTextField(wrappingLabelWithString: "")
    private var motion: (id: String, start: Double, frame: CGRect)?
    private var spawnIndex = 0

    init(world: SyntheticWorld, canvas: SyntheticCanvas, height panelHeight: CGFloat) {
        self.world = world; self.canvas = canvas
        view = NSView(frame: CGRect(x: 0, y: 0, width: 250, height: panelHeight))
        super.init()
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16)])
        func label(_ title: String, bold: Bool = false) {
            let label = NSTextField(wrappingLabelWithString: title)
            label.font = bold ? .boldSystemFont(ofSize: 16) : .systemFont(ofSize: 11)
            stack.addArrangedSubview(label)
        }
        func row(_ title: String, _ control: NSView) {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12)
            label.widthAnchor.constraint(equalToConstant: 92).isActive = true
            let row = NSStackView(views: [label, control]); row.spacing = 8
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if let field = control as? NSTextField { field.setAccessibilityLabel(title) }
        }
        func button(_ title: String, _ action: Selector) {
            let b = NSButton(title: title, target: self, action: action)
            stack.addArrangedSubview(b)
            b.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        label("Synthetic sandbox", bold: true)
        label("Drag teal objects. Orange dashed outlines show the collision geometry received by physics.")
        type.addItems(withTitles: world.registry.names); type.selectItem(withTitle: "window")
        type.target = self; type.action = #selector(typeChanged)
        row("Spawn type", type)
        row("Width (pt)", width); row("Height (pt)", height)
        row("Poll rate (Hz)", hz); row("Delay (ms)", delay)
        button("Spawn obstacle", #selector(spawn))
        objects.target = self; objects.action = #selector(objectChanged)
        row("Selection", objects)
        stack.addArrangedSubview(selection)
        button("Apply timing to selected", #selector(applyTiming))
        button("Move up 200 pt in 2 s", #selector(moveUp))
        button("Remove selected", #selector(remove))
        button("Save current layout…", #selector(saveLayout))
        stack.addArrangedSubview(message)
        message.textColor = .systemOrange; message.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(status); status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        canvas.onSelection = { [weak self] id in self?.select(id) }
        canvas.onMove = { [weak self] in self?.motion = nil }
        typeChanged(); refreshObjects()
    }
    @objc private func typeChanged() {
        guard let name = type.titleOfSelectedItem, let definition = world.registry.types[name] else { return }
        hz.doubleValue = definition.hz!; delay.doubleValue = definition.delayMs!
        let size: (Double, Double)
        switch definition.shape {
        case "widget": size = (200, 160)
        case "folder", "icon": size = (80, 80)
        case "dock": size = (500, 65)
        default: size = (320, 200)
        }
        width.doubleValue = size.0; height.doubleValue = size.1
    }
    private func timing() throws -> (Double, Double) {
        guard let h = Double(hz.stringValue), let d = Double(delay.stringValue) else { throw SyntheticError.invalid("Enter numeric Hz and delay values") }
        try SyntheticTypeRegistry.validateTiming(hz: h, delay: d); return (h, d)
    }
    @objc private func spawn() {
        do {
            let (h, d) = try timing()
            guard let w = Double(width.stringValue), let height = Double(height.stringValue),
                  w.isFinite, height.isFinite, (20...4096).contains(w), (20...4096).contains(height) else {
                throw SyntheticError.invalid("Width and height must be 20–4096 points")
            }
            let offset = Double(spawnIndex % 6) * 24; spawnIndex += 1
            let frame = CGRect(x: max(0, (world.scenario.width - w) / 2 + offset),
                               y: max(5, (world.scenario.height - height) / 2 + offset), width: w, height: height)
            let id = try world.spawn(type: type.titleOfSelectedItem!, frame: frame, hz: h, delayMs: d)
            refreshObjects(); select(id); message.stringValue = ""
        } catch { message.stringValue = error.localizedDescription }
    }
    private func select(_ id: String?) {
        canvas.selected = id
        if let obstacle = world.obstacles.first(where: { $0.spec.id == id }) {
            selection.stringValue = "\(obstacle.spec.id) · \(obstacle.spec.type)"
            hz.doubleValue = obstacle.hz; delay.doubleValue = obstacle.delayMs
            objects.selectItem(withTitle: obstacle.spec.id)
        } else { selection.stringValue = "No obstacle selected"; objects.selectItem(at: 0) }
    }
    private func refreshObjects() {
        let current = canvas.selected
        objects.removeAllItems(); objects.addItem(withTitle: "None")
        objects.addItems(withTitles: world.obstacles.filter { $0.frame(at: world.time) != nil }.map { $0.spec.id })
        if let current, objects.itemTitles.contains(current) { objects.selectItem(withTitle: current) }
    }
    @objc private func objectChanged() { select(objects.indexOfSelectedItem > 0 ? objects.titleOfSelectedItem : nil) }
    @objc private func applyTiming() {
        guard let id = canvas.selected else { message.stringValue = "Select an obstacle first"; return }
        do { let (h, d) = try timing(); try world.setTiming(id: id, hz: h, delayMs: d); message.stringValue = "Timing applied; pending samples cleared" }
        catch { message.stringValue = error.localizedDescription }
    }
    @objc private func moveUp() {
        guard let id = canvas.selected, let frame = world.obstacles.first(where: { $0.spec.id == id })?.frame(at: world.time) else {
            message.stringValue = "Select an obstacle first"; return
        }
        motion = (id, world.time, frame); message.stringValue = ""
    }
    @objc private func remove() {
        guard let id = canvas.selected else { return }
        world.remove(id: id); motion = nil; refreshObjects(); select(nil)
    }
    func beforeFrame(at time: Double) {
        if let m = motion {
            var frame = m.frame
            frame.origin.y += min(1, max(0, (time - m.start) / 2)) * 200
            world.move(id: m.id, to: frame, at: time)
            if time - m.start >= 2 { motion = nil }
        }
    }
    func tick() { refreshObjects() }
    @objc private func saveLayout() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "sandbox.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var snapshot = world.scenario
        snapshot.obstacles = world.obstacles.compactMap { obstacle in
            guard let f = obstacle.frame(at: world.time) else { return nil }
            return .init(id: obstacle.spec.id, type: obstacle.spec.type, frame: [f.minX, f.minY, f.width, f.height],
                         hz: obstacle.hz, delayMs: obstacle.delayMs)
        }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url, options: .atomic)
            message.stringValue = "Layout saved"
        } catch { message.stringValue = error.localizedDescription }
    }
}
