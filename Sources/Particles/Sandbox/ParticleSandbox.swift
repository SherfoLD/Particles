import AppKit
import MetalKit
#if SWIFT_PACKAGE
import LayoutCore
#endif

/// An ordinary app window with synthetic obstacles. It never creates a reader or
/// Dock tracker, so testing requires no desktop information or permissions.
@MainActor
final class ParticleSandboxDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var scene: ParticleScene?
    private weak var metalView: MTKView?
    private var timer: Timer?
    private var started = 0.0
    private var world: SyntheticWorld?
    private var controls: SyntheticSandboxControls?
    private var log: SyntheticLog?
    private var scenarioDuration: Double?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        do {
            let scenario = try SyntheticScenario.fromArguments()
            let world = try SyntheticFixtures.isSelected ? nil : SyntheticWorld(scenario ?? .playground)
            self.world = world
            scenarioDuration = scenario?.duration
            log = try SyntheticLog.fromArguments()
            let size = CGSize(width: world?.scenario.width ?? 1200, height: world?.scenario.height ?? 760)
            let count = LaunchArguments.value("--count", default: 3_000)
            let bounds = CGRect(origin: .zero, size: size)
            let engine = SyntheticFixtures.usesPile
                ? SyntheticFixtures.pile(count: count, bounds: bounds, radius: LaunchArguments.ballRadius)
                : .rain(count: count, bounds: bounds, radius: LaunchArguments.ballRadius)
            engine.maximumSpeed = LaunchArguments.ballSpeed
            let scene = try ParticleScene(engine: engine)
            self.scene = scene
            scene.collectMetrics = true
            let view = scene.makeView(size: size)
            metalView = view
            let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
            let panelWidth: CGFloat = world == nil ? 0 : 250
            let scale = min(1, (available.width - panelWidth - 20) / size.width, (available.height - 60) / size.height)
            let canvasSize = CGSize(width: size.width * scale, height: size.height * scale)
            let contentHeight = min(available.height - 40, max(world == nil ? 0 : 680, canvasSize.height))
            view.frame = CGRect(x: 0, y: (contentHeight - canvasSize.height) / 2, width: canvasSize.width, height: canvasSize.height)
            let content = NSView(frame: CGRect(origin: .zero, size: CGSize(width: canvasSize.width + panelWidth, height: contentHeight)))
            let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            self.window = window
            window.title = "Particle Lab — Metal · 3,000 particles · 120 fps target"
            window.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1)
            window.isReleasedWhenClosed = false
            window.contentView = content
            content.addSubview(view)
            var canvas: SyntheticCanvas?
            if let world {
                let overlay = SyntheticCanvas(world: world, frame: view.frame)
                overlay.bounds = CGRect(origin: .zero, size: size)
                content.addSubview(overlay); canvas = overlay
                let controls = SyntheticSandboxControls(world: world, canvas: overlay, height: contentHeight)
                self.controls = controls
                controls.view.frame.origin.x = canvasSize.width
                content.addSubview(controls.view)
            }
            let outlines = CAShapeLayer()
            outlines.strokeColor = NSColor.systemTeal.cgColor
            outlines.fillColor = NSColor.systemTeal.withAlphaComponent(0.15).cgColor
            outlines.lineWidth = 1
            view.layer?.addSublayer(outlines)
            started = ProcessInfo.processInfo.systemUptime
            var nextGeometry = 0.0
            let pileDrag = SyntheticFixtures.usesPile
            let withWindows = pileDrag || CommandLine.arguments.contains("--window-fixtures")
            let started = started
            scene.beforeFrame = { [weak self, weak scene, weak canvas] time in
                guard let scene else { return false }
                SyntheticFixtures.updateCursor(in: scene.engine, time: time - started)
                SyntheticFixtures.updateMotion(in: scene.engine, time: time - started)
                if let world {
                    self?.controls?.beforeFrame(at: time - started)
                    world.advance(to: time - started, engine: scene.engine)
                    canvas?.needsDisplay = true
                    return true
                }
                guard time >= nextGeometry else { return true }
                let interval = withWindows ? 1.0 / 60 : 0.1
                nextGeometry += interval
                if nextGeometry < time { nextGeometry = time + interval }
                if withWindows {
                    scene.engine.windowObstacles = SyntheticFixtures.windowFixtures(in: scene.engine.bounds, time: time - started)
                }
                scene.engine.collisionShapes = pileDrag ? [] : SyntheticFixtures.fixtures(in: scene.engine.bounds, time: time - started)
                let path = CGMutablePath()
                for shape in scene.engine.collisionShapes { path.addPath(shape.path) }
                for rect in scene.engine.windowObstacles {
                    let radius = rect.contains(scene.engine.bounds) ? 0 : scene.engine.windowCornerRadius
                    path.addPath(WindowCornerCurve.path(in: rect, radius: radius))
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                outlines.path = path
                CATransaction.commit()
                return true
            }
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            NSLog("Particle Lab: %@", error.localizedDescription)
            fputs("Sandbox failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private func tick() {
        guard let scene else { return }
        let report = scene.metrics.report()
        let fps = report["presentedFPS"] as? Double ?? 0
        window?.title = String(format: "Particle Lab — %d particles · %.1f presented fps · CPU p95 %.2f ms", scene.engine.particles.count, fps, PerformanceReport.summary(scene.cpuTimes)["p95"] ?? 0)
        controls?.tick()
        controls?.status.stringValue = String(format: "%.1f s · %.1f presented fps\nCPU p95 %.2f ms · GPU p95 %.2f ms\n%d skipped submissions", ProcessInfo.processInfo.systemUptime - started, fps,
            PerformanceReport.summary(scene.cpuTimes)["p95"] ?? 0,
            (report["gpuMs"] as? [String: Double])?["p95"] ?? 0, scene.skippedFrames)
        do { try log?.write(["mode": "sandbox-sample", "render": report, "cpuFrameMs": PerformanceReport.summary(scene.cpuTimes),
                             "skippedFrames": scene.skippedFrames, "synthetic": world?.report() ?? [:]]) }
        catch { fputs("Sandbox log failed: \(error.localizedDescription)\n", stderr); exit(1) }
        let duration = CommandLine.arguments.contains("--duration")
            ? Double(LaunchArguments.value("--duration", default: 15)) : scenarioDuration
        if let duration, ProcessInfo.processInfo.systemUptime - started >= duration {
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        guard let scene else { return }
        metalView?.isPaused = true
        // Drain submitted frames before reporting their completion/presentation metrics.
        let drain = scene.renderer.queue.makeCommandBuffer()
        drain?.commit(); drain?.waitUntilCompleted()
        var report = scene.metrics.report()
        report["mode"] = "sandbox"
        report["particles"] = scene.engine.particles.count
        report["physicsBackend"] = scene.renderer.simulation == nil ? "cpu" : "metal"
        report["cpuFrameMs"] = PerformanceReport.summary(scene.cpuTimes)
        report["skippedFrames"] = scene.skippedFrames
        report["displayMaximumFPS"] = window?.screen?.maximumFramesPerSecond ?? 0
        report["synthetic"] = world?.report()
        if let simulation = scene.renderer.simulation {
            let particles = simulation.snapshot().filter(\.isActive).map {
                Particle(position: CGPoint(x: CGFloat($0.positionRadius.x), y: CGFloat($0.positionRadius.y)),
                         velocity: CGVector(dx: CGFloat($0.velocity.x), dy: CGFloat($0.velocity.y)), radius: CGFloat($0.positionRadius.z))
            }
            report["activeParticles"] = particles.count
            report["despawnedParticles"] = scene.engine.particles.count - particles.count
            report["simulationHealth"] = PerformanceReport.health(particles, engine: scene.engine)
        } else {
            report["activeParticles"] = scene.engine.particles.count
            report["simulationHealth"] = PerformanceReport.health(scene.engine.particles, engine: scene.engine)
        }
        do { try log?.write(report); try log?.close() }
        catch { fputs("Sandbox log failed: \(error.localizedDescription)\n", stderr); exit(1) }
        PerformanceReport.printJSON(report)
    }
}
