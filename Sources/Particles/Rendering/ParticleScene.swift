import AppKit
import MetalKit
#if SWIFT_PACKAGE
import LayoutCore
#endif

final class TransparentParticleView: MTKView {
    override var isOpaque: Bool { false }
}

/// The GPU writes this dedicated buffer once; only its command's completion
/// callback reads it. No subsequent frame can mutate the snapshot.
private final class GPUProfileSnapshot: @unchecked Sendable {
    let buffer: MTLBuffer
    init(_ buffer: MTLBuffer) { self.buffer = buffer }
}

/// Completion callbacks execute off the main thread; protect timing samples.
final class RenderMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var gpu: [Double] = []
    private var presented: [Double] = []
    private var errors = 0
    func completed(_ command: MTLCommandBuffer) {
        lock.lock(); defer { lock.unlock() }
        if command.status == .error { errors += 1 }
        if command.gpuEndTime > command.gpuStartTime { gpu.append((command.gpuEndTime - command.gpuStartTime) * 1000) }
        if gpu.count > 16_384 { gpu.removeFirst(8_192) }
    }
    func didPresent(at time: Double) {
        guard time > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        presented.append(time)
        if presented.count > 16_384 { presented.removeFirst(8_192) }
    }
    func report() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let sorted = presented.sorted()
        let intervals = zip(sorted.dropFirst(), sorted).map { ($0 - $1) * 1000 }
        return ["gpuMs": PerformanceReport.summary(gpu), "gpuFrames": gpu.count, "gpuErrors": errors,
                "presentedFrames": sorted.count, "presentationIntervalMs": PerformanceReport.summary(intervals),
                "presentedFPS": sorted.count > 1 ? Double(sorted.count - 1) / (sorted.last! - sorted.first!) : 0]
    }
}

@MainActor
final class ParticleScene: NSObject, MTKViewDelegate {
    let engine: ParticleEngine
    let renderer: ParticleRenderer
    /// Return false to preserve the current particle frame without advancing physics.
    var beforeFrame: ((Double) -> Bool)?
    let metrics = RenderMetrics()
    private(set) var cpuTimes: [Double] = []
    private(set) var skippedFrames = 0
    var collectMetrics = false
    private let profiling = CommandLine.arguments.contains("--profile-physics")
    private var lastProfileTime = 0.0

    convenience init(size: CGSize, count: Int, seed: UInt64 = 42) throws {
        try self.init(engine: .rain(count: count, bounds: CGRect(origin: .zero, size: size), seed: seed))
    }

    init(engine: ParticleEngine) throws {
        self.engine = engine
        renderer = try ParticleRenderer(engine: engine, useGPU: !CommandLine.arguments.contains("--cpu-physics"),
                                        collectDiagnostics: CommandLine.arguments.contains("--profile-physics"))
        super.init()
    }

    func makeView(size: CGSize) -> MTKView {
        let view = TransparentParticleView(frame: CGRect(origin: .zero, size: size), device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.preferredFramesPerSecond = 120
        view.delegate = self
        return view
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        autoreleasepool {
            let start = ProcessInfo.processInfo.systemUptime
            guard beforeFrame?(start) ?? true else { return }
            let geometryEnd = ProcessInfo.processInfo.systemUptime
            guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else {
                skippedFrames += 1
                return
            }
            let drawableEnd = ProcessInfo.processInfo.systemUptime
            let command: MTLCommandBuffer
            do {
                guard let encoded = try renderer.encode(at: start, size: engine.bounds.size, pass: pass) else {
                    skippedFrames += 1
                    return
                }
                command = encoded
            } catch {
                NSLog("Particle simulation stopped: %@", error.localizedDescription)
                view.isPaused = true
                return
            }
            if collectMetrics {
                let metrics = metrics
                command.addCompletedHandler { metrics.completed($0) }
                drawable.addPresentedHandler { metrics.didPresent(at: $0.presentedTime) }
                cpuTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                if cpuTimes.count > 16_384 { cpuTimes.removeFirst(8_192) }
            }
            if profiling, start - lastProfileTime >= 1 {
                lastProfileTime = start
                let snapshot = renderer.simulation?.encodeDiagnosticsReadback(into: command).map(GPUProfileSnapshot.init)
                let steps = renderer.simulation?.encodedSteps ?? 0
                let count = engine.particles.count, windows = engine.windowObstacles.count
                let cpuMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
                let encodeMs = renderer.physicsEncodeMs
                command.addCompletedHandler { command in
                    var report: [String: Any] = ["mode": "desktop-profile", "time": start, "particles": count,
                                                "windows": windows, "substeps": steps, "cpuMs": cpuMs,
                                                "geometryCPUTimeMs": (geometryEnd - start) * 1000,
                                                "drawableWaitMs": (drawableEnd - geometryEnd) * 1000,
                                                "physicsCPUEncodeMs": encodeMs,
                                                "gpuMs": (command.gpuEndTime - command.gpuStartTime) * 1000]
                    if let snapshot {
                        let data = snapshot.buffer.contents().assumingMemoryBound(to: UInt32.self)
                        report["gridRebuilds"] = data[0]
                        report["overflowedNeighborLists"] = data[1]
                        report["maximumNeighbors"] = data[2]
                        report["compressionDespawns"] = data[3]
                        report["invalidStateDespawns"] = data[4]
                        report["workLimitDespawns"] = data[5]
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                        FileHandle.standardError.write(data + Data([10]))
                    }
                }
            }
            command.present(drawable)
            command.commit()
        }
    }
}
