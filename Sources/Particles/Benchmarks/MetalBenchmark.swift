import AppKit
import MetalKit
#if SWIFT_PACKAGE
import LayoutCore
#endif

@MainActor
enum MetalBenchmark {
    static func run() throws {
        let scenario = try SyntheticScenario.fromArguments()
        let world = try scenario.map(SyntheticWorld.init)
        let log = try SyntheticLog.fromArguments()
        let count = LaunchArguments.value("--count", default: 3_000)
        let cannon = CommandLine.arguments.contains("--cannon-fixture")
        let compressed = CommandLine.arguments.contains("--compressed-pile-fixture")
        let pileDrag = SyntheticFixtures.usesPile
        let narrowFixture = SyntheticFixtures.squeezeFixture || SyntheticFixtures.settledFixture
        let frames = LaunchArguments.value("--frames", default: scenario.map { Int(ceil($0.duration * 120)) } ?? (compressed ? 360 : (pileDrag && !narrowFixture ? 8640 : 1440)))
        let withWindows = pileDrag || CommandLine.arguments.contains("--window-fixtures")
        let windowHz = min(120, LaunchArguments.value("--window-poll-hz", default: 60))
        let size = CGSize(width: scenario?.width ?? 1440, height: scenario?.height ?? 900)
        let narrow = compressed || narrowFixture
        let bounds = CGRect(origin: .zero, size: narrow ? CGSize(width: 360, height: 900) : size)
        let radius = LaunchArguments.ballRadius
        let engine = cannon ? ParticleEngine.cannon(bounds: bounds, capacity: count, radius: radius)
            : (pileDrag ? SyntheticFixtures.pile(count: count, bounds: bounds, radius: radius)
               : ParticleEngine.rain(count: count, bounds: bounds, radius: radius))
        engine.maximumSpeed = LaunchArguments.ballSpeed
        let cannonPlacement = cannon ? CannonPlacement(bounds: bounds) : nil
        var fixtureShapes: [CollisionShape] = []
        let renderer = try ParticleRenderer(engine: engine, useGPU: !CommandLine.arguments.contains("--cpu-physics"),
                                            collectDiagnostics: CommandLine.arguments.contains("--profile-physics"))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width * 2), height: Int(size.height * 2), mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let texture = renderer.device.makeTexture(descriptor: descriptor) else { throw failure("Texture allocation failed") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        var physics: [Double] = [], cpu: [Double] = [], gpu: [Double] = [], total: [Double] = []
        var phases = [[Double]](repeating: [], count: 3)
        var neighborPhases: [[String: UInt32]] = []
        var squeezePhases = [[Double]](repeating: [], count: 4)
        var settledMotion: [Double] = []
        var geometryTimes: [Double] = []
        var previousPositions: [MetalParticleSimulation.State]?
        engine.update(at: 0)
        world?.advance(to: 0, engine: engine)
        if let simulation = renderer.simulation {
            guard let command = renderer.queue.makeCommandBuffer() else { throw failure("Command allocation failed") }
            try simulation.encode(at: 0, into: command)
            command.commit()
            command.waitUntilCompleted()
        }
        for frame in 1...frames {
            try autoreleasepool {
                let time = Double(frame) / 120
                if world == nil, !pileDrag, frame % 12 == 1 {
                    fixtureShapes = SyntheticFixtures.fixtures(in: engine.bounds, time: time)
                    engine.collisionShapes = fixtureShapes
                }
                let start = ProcessInfo.processInfo.systemUptime
                SyntheticFixtures.updateCursor(in: engine, time: time)
                SyntheticFixtures.updateMotion(in: engine, time: time)
                if cannon {
                    // Sustained maximum-rate emission exercises growing dispatches,
                    // immutable uploads, cache invalidation and pool wraparound.
                    let angle = 1.1 + sin(time * 2.1) * 0.28
                    let speed = engine.maximumSpeed * (0.925 + sin(time * 7.3) * 0.075)
                    engine.emit(position: CGPoint(x: bounds.midX + sin(time * 0.8) * 200, y: bounds.height * 0.65),
                                velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed))
                }
                world?.advance(to: time, engine: engine)
                if withWindows, frame == 1 || (frame - 1) * windowHz / 120 != (frame - 2) * windowHz / 120 {
                    engine.windowObstacles = SyntheticFixtures.windowFixtures(in: engine.bounds, time: time)
                }
                if let cannonPlacement {
                    // Include the production placement/search and collision shapes.
                    // Emission above stays at maximum rate even while placement is
                    // blocked, so the fixture still exercises pool recycling.
                    cannonPlacement.updateObstacles(fixtureShapes, windows: engine.windowObstacles, cornerRadius: engine.windowCornerRadius)
                    engine.collisionShapes = fixtureShapes + cannonPlacement.collisionShapes
                }
                geometryTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                guard let command = try renderer.encode(at: time, size: size, pass: pass) else { throw failure("Frame submission failed") }
                physics.append(renderer.physicsEncodeMs)
                command.commit()
                cpu.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                command.waitUntilCompleted()
                if let error = command.error { throw error }
                gpu.append((command.gpuEndTime - command.gpuStartTime) * 1000)
                total.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                if let log, let world {
                    try log.write(["mode": "synthetic-frame", "frame": frame, "time": time,
                                   "serialFrameMs": total.last!, "gpuMs": gpu.last!, "geometryMs": geometryTimes.last!,
                                   "synthetic": world.currentSample()])
                }
                phases[min(2, (frame - 1) * 3 / frames)].append(total.last!)
                if SyntheticFixtures.squeezeFixture {
                    squeezePhases[time < 2 ? 0 : (time < 4 ? 1 : (time < 6 ? 2 : 3))].append(total.last!)
                }
                // Untimed readback during the last second measures visible
                // pile jitter; a fast solver must not hide it by removing balls.
                if SyntheticFixtures.settledFixture, frame > frames - 120, let simulation = renderer.simulation {
                    let snapshot = simulation.snapshot()
                    if let previousPositions {
                        var largestMotion = 0.0
                        for (a, b) in zip(snapshot, previousPositions) where a.isActive && b.isActive {
                            largestMotion = max(largestMotion, hypot(Double(a.positionRadius.x - b.positionRadius.x),
                                                                    Double(a.positionRadius.y - b.positionRadius.y)))
                        }
                        settledMotion.append(largestMotion)
                    }
                    previousPositions = snapshot
                }
                if frame % max(1, frames / 3) == 0, let simulation = renderer.simulation {
                    neighborPhases.append(simulation.diagnostics())
                }
            }
        }
        let bytesPerRow = texture.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        pixels.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0) }
        var visible = 0, transparent = 0, partial = 0, invalidPremultiplication = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = pixels[i + 3]
            if alpha > 0 { visible += 1 } else { transparent += 1 }
            if alpha > 0 && alpha < 255 { partial += 1 }
            if pixels[i] > alpha || pixels[i + 1] > alpha || pixels[i + 2] > alpha { invalidPremultiplication += 1 }
        }
        let args = CommandLine.arguments
        let finalParticles: [Particle]
        if let simulation = renderer.simulation {
            finalParticles = simulation.snapshot().filter(\.isActive).map {
                Particle(position: CGPoint(x: CGFloat($0.positionRadius.x), y: CGFloat($0.positionRadius.y)),
                         velocity: CGVector(dx: CGFloat($0.velocity.x), dy: CGFloat($0.velocity.y)), radius: CGFloat($0.positionRadius.z))
            }
        } else { finalParticles = Array(engine.particles.prefix(engine.activeParticleCount)) }
        guard transparent > 0, invalidPremultiplication == 0,
              (finalParticles.isEmpty ? visible == 0 : (visible > 0 && partial > 0)) else { throw failure("Transparent render validation failed") }
        let health = PerformanceReport.health(finalParticles, engine: engine)
        guard health["nonfiniteParticles"] == 0, health["wallViolations"] == 0,
              health["windowClearanceViolations"] == 0,
              (health["maxSpeed"] ?? .infinity) <= Double(engine.maximumSpeed) + 0.01
        else { throw failure("Simulation health check failed: \(health)") }
        if SyntheticFixtures.settledFixture, finalParticles.count != count {
            throw failure("Resting-pile performance is invalid: \(count - finalParticles.count) balls despawned")
        }
        if args.contains("--pile-drag-fixture"), finalParticles.count != count {
            throw failure("Window-drag performance is invalid: \(count - finalParticles.count) balls despawned")
        }
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            let data = Data(pixels) as CFData
            let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
            guard let provider = CGDataProvider(data: data),
                  let image = CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw failure("PNG encoding failed") }
            try png.write(to: URL(fileURLWithPath: args[index + 1]))
        }
        let report: [String: Any] = ["mode": "offscreen-metal", "physicsBackend": renderer.simulation == nil ? "cpu" : "metal",
                                     "device": renderer.device.name, "particles": count, "frames": frames,
                                     "activeParticles": finalParticles.count, "despawnedParticles": engine.activeParticleCount - finalParticles.count,
                                     "simulationHealth": health,
                                     "fixture": cannon ? "cannon" : (world != nil ? "scenario" : SyntheticFixtures.reportName),
                                     "synthetic": world?.report() ?? [:], "geometryMs": PerformanceReport.summary(geometryTimes),
                                     "phaseSerialFrameMs": phases.map(PerformanceReport.summary),
                                     "phaseNeighborDiagnostics": neighborPhases,
                                     "squeezePhaseSerialFrameMs": Dictionary(uniqueKeysWithValues: zip(["settle", "compress", "held", "released"], squeezePhases.map(PerformanceReport.summary))),
                                     "settledMaxMotionPerFrame": PerformanceReport.summary(settledMotion),
                                     "simulationHz": 240, "contactIterations": renderer.simulation?.contactIterations ?? 12,
                                     "maximumSpeed": engine.maximumSpeed, "ballRadius": radius,
                                     "integrationSubsteps": engine.integrationSubsteps,
                                     "cursorCollisions": SyntheticFixtures.cursorFixture,
                                     "deviceMotion": CommandLine.arguments.contains("--motion-fixture"),
                                     "windowObstacles": engine.windowObstacles.count,
                                     "windowPollHz": windowHz,
                                     "dragHz": LaunchArguments.value("--drag-hz", default: 1),
                                     "texturePixels": [texture.width, texture.height], "physicsCPUEncodeMs": PerformanceReport.summary(physics),
                                     "cpuEncodeAndPhysicsMs": PerformanceReport.summary(cpu), "gpuMs": PerformanceReport.summary(gpu),
                                     "serialFrameMs": PerformanceReport.summary(total), "framesOver120HzBudget": total.filter { $0 > 1000 / 120 }.count,
                                     "alphaValidation": ["visiblePixels": visible, "transparentPixels": transparent, "antialiasedPixels": partial,
                                                         "invalidPremultiplication": invalidPremultiplication]]
        PerformanceReport.printJSON(report)
        try log?.write(report); try log?.close()
        if args.contains("--require-120fps"), (PerformanceReport.summary(total)["p95"] ?? .infinity) > 1000 / 120 {
            throw failure("p95 serial frame time exceeded the 8.33 ms budget; see JSON report")
        }
        if args.contains("--require-120fps"), SyntheticFixtures.squeezeFixture {
            for (name, samples) in zip(["settle", "compress", "held", "released"], squeezePhases) where !samples.isEmpty {
                if (PerformanceReport.summary(samples)["p95"] ?? .infinity) > 1000 / 120 {
                    throw failure("Squeeze phase \(name) exceeded the 8.33 ms p95 budget; see JSON report")
                }
            }
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "MetalBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
