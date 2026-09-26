import Foundation
import CoreGraphics
import Metal

/// GPU-owned state, shared by compute and rendering on a single command queue.
/// ParticleEngine supplies configuration; its Particle objects are only the seed.
/// Call snapshot() after GPU completion for diagnostics, never in the frame loop.
@MainActor
public final class MetalParticleSimulation {
    public struct State {
        /// x, y, radius, palette index. The vertex shader reads this directly.
        public var positionRadius: SIMD4<Float>
        /// vx, vy, compression time (-1 means despawned), window radius group.
        public var velocity: SIMD4<Float>
        public var isActive: Bool { velocity.z >= 0 }
    }

    private struct Parameters {
        var bounds: SIMD4<Float>
        var dynamics: SIMD4<Float>
        var counts: SIMD4<UInt32> // particles, hash mask, rectangles, polygons
        var geometry: SIMD4<UInt32> // windows, curve edges, restitution flag, cache generation
        var limits: SIMD4<Float> // speed, compression time per contact pass, horizontal acceleration, cursor sweep
        var cursorSegment: SIMD4<Float> // previous/current position
        var cursorMotion: SIMD4<Float> // velocity, radius (zero disables), inverse segment length squared
        var cursorBounds: SIMD4<Float> // swept capsule bounds
    }

    private let engine: ParticleEngine
    private let device: MTLDevice
    private let integrate: MTLComputePipelineState
    private let clear: MTLComputePipelineState
    private let build: MTLComputePipelineState
    private let solve: MTLComputePipelineState
    private let cacheNeighbors: MTLComputePipelineState
    private let states: [MTLBuffer]
    private let heads: MTLBuffer
    private let links: MTLBuffer
    private let neighbors: MTLBuffer
    private let referencePositions: MTLBuffer
    private let rebuild: MTLBuffer
    private let statistics: MTLBuffer
    private let collectDiagnostics: Bool
    private let curve: MTLBuffer
    private var shapes: MTLBuffer
    private var edges: MTLBuffer
    private var windows: MTLBuffer
    private var rectangles: MTLBuffer
    private var exits: MTLBuffer
    private let radii: [CGFloat]
    private var counts = SIMD4<UInt32>(repeating: 0)
    private var geometryRevision: UInt64?
    private var clockRevision: UInt64
    private var previousTime: Double?
    private var accumulatedTime = 0.0
    private var current = 0
    private var iterationGeneration: UInt32 = 1
    private let bucketCount: Int
    private let inverseCellSize: Float
    private let skin: Float
    private let step = 1.0 / 240.0
    public let contactIterations = ParticleComputeKernels.contactIterations
    public private(set) var encodedSteps = 0

    public var particleBuffer: MTLBuffer { states[current] }

    public init(engine: ParticleEngine, device: MTLDevice, collectDiagnostics: Bool = false) throws {
        self.engine = engine
        self.device = device
        self.collectDiagnostics = collectDiagnostics
        clockRevision = engine.clockRevision
        let options = MTLCompileOptions()
        // The solver's invalid-state guards must survive shader optimization.
        options.fastMathEnabled = false
        let library = try device.makeLibrary(source: ParticleComputeKernels.source, options: options)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw Self.failure("Missing kernel: \(name)") }
            return try device.makeComputePipelineState(function: function)
        }
        integrate = try pipeline("integrateParticles")
        clear = try pipeline("clearGrid")
        build = try pipeline("buildGrid")
        solve = try pipeline("solveContacts")
        cacheNeighbors = try pipeline("cacheNeighbors")
        let radii = Array(Set(engine.particles.map(\.radius))).sorted()
        self.radii = radii
        let radiusIndices = Dictionary(uniqueKeysWithValues: radii.enumerated().map { ($1, $0) })
        let initial = engine.particles.enumerated().map { i, p in
            State(positionRadius: SIMD4(Float(p.position.x), Float(p.position.y), Float(p.radius), Float(i % 7)),
                  velocity: SIMD4(Float(p.velocity.dx), Float(p.velocity.dy), 0, Float(radiusIndices[p.radius]!)))
        }
        states = try [Self.buffer(initial, device: device), Self.buffer(initial, device: device)]
        var buckets = 1
        while buckets < max(1, initial.count * 2) { buckets *= 2 }
        bucketCount = buckets
        skin = Float(engine.particles.map(\.radius).max() ?? 1.5)
        inverseCellSize = 1 / (skin * 3)
        guard let heads = device.makeBuffer(length: buckets * 4, options: .storageModePrivate),
              let links = device.makeBuffer(length: max(1, initial.count) * 16, options: .storageModePrivate) else {
            throw Self.failure("Grid allocation failed")
        }
        self.heads = heads
        self.links = links
        guard let neighbors = device.makeBuffer(length: max(1, initial.count) * (ParticleComputeKernels.neighborCapacity + 1) * 4, options: .storageModePrivate),
              let referencePositions = device.makeBuffer(length: max(1, initial.count) * 8, options: .storageModePrivate) else {
            throw Self.failure("Neighbor cache allocation failed")
        }
        self.neighbors = neighbors
        self.referencePositions = referencePositions
        rebuild = try Self.buffer([UInt32(1)], device: device)
        statistics = try Self.buffer([UInt32](repeating: 0, count: 6), device: device)
        let curveData = WindowCornerCurve.edges.flatMap { edge in
            [SIMD4(Float(edge.x), Float(edge.y), Float(edge.dx), Float(edge.dy)),
             SIMD4(Float(edge.inverseLengthSquared), Float(edge.nx), Float(edge.ny), 0)]
        }
        curve = try Self.buffer(curveData, device: device)
        let empty = try Self.buffer([SIMD4<Float>(repeating: 0)], device: device)
        shapes = empty; edges = empty; windows = empty; rectangles = empty; exits = empty
        states[0].label = "Particle state A"; states[1].label = "Particle state B"
        heads.label = "Spatial hash heads"; links.label = "Spatial hash links"
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "MetalParticleSimulation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func buffer<T>(_ values: [T], device: MTLDevice) throws -> MTLBuffer {
        let result: MTLBuffer?
        if values.isEmpty {
            result = device.makeBuffer(length: 16, options: .storageModeShared)
        } else {
            result = values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        }
        guard let result else { throw failure("Buffer allocation failed") }
        return result
    }

    private func updateGeometry() throws {
        guard geometryRevision != engine.geometryRevision else { return }
        var shapeData: [SIMD4<Float>] = [], edgeData: [SIMD4<Float>] = []
        for shape in engine.collisionShapes {
            shapeData.append(SIMD4(Float(shape.minX), Float(shape.minY), Float(shape.maxX), Float(shape.maxY)))
            shapeData.append(SIMD4(Float(edgeData.count / 2), Float(shape.edges.count), 0, 0))
            for edge in shape.edges {
                edgeData.append(SIMD4(Float(edge.start.x), Float(edge.start.y), Float(edge.dx), Float(edge.dy)))
                edgeData.append(SIMD4(Float(1 / edge.lengthSquared), Float(edge.nx), Float(edge.ny), 0))
            }
        }
        let validWindows = engine.windowObstacles.filter { !$0.isEmpty && !$0.isNull && !$0.isInfinite &&
            $0.origin.x.isFinite && $0.origin.y.isFinite && $0.width.isFinite && $0.height.isFinite
        }
        let windowData = validWindows.flatMap { rect in
            let collider = RoundedWindowCollider(rect, radius: rect.contains(engine.bounds) ? 0 : engine.windowCornerRadius)
            return [SIMD4(Float(collider.centerX), Float(collider.centerY), Float(collider.halfWidth), Float(collider.halfHeight)),
                    SIMD4(Float(collider.radius), Float(collider.extent), 0, 0)]
        }
        let rectData = engine.obstacles.filter { !$0.isEmpty && !$0.isNull }.map {
            SIMD4(Float($0.minX), Float($0.minY), Float($0.maxX), Float($0.maxY))
        }
        // Immutable uploads are retained by the command buffer, including when
        // geometry changes while an older frame is still executing.
        let newShapes = try Self.buffer(shapeData, device: device)
        let newEdges = try Self.buffer(edgeData, device: device)
        let newWindows = try Self.buffer(windowData, device: device)
        let newRectangles = try Self.buffer(rectData, device: device)
        var exitData = [SIMD4<Float>](repeating: .zero, count: radii.count)
        for (i, radius) in radii.enumerated() {
            let segments = WindowUnionBoundary.segments(windows: validWindows, cornerRadius: engine.windowCornerRadius,
                                                        ballRadius: radius, bounds: engine.bounds)
            exitData[i] = SIMD4(Float(exitData.count), Float(segments.count / 2), 0, 0)
            exitData += segments
        }
        let newExits = try Self.buffer(exitData, device: device)
        shapes = newShapes; edges = newEdges; windows = newWindows; rectangles = newRectangles; exits = newExits
        counts = SIMD4(UInt32(rectData.count), UInt32(shapeData.count / 2), UInt32(windowData.count / 2), UInt32(WindowCornerCurve.edges.count))
        geometryRevision = engine.geometryRevision
    }

    /// Encode all substeps in one compute encoder. Explicit buffer barriers
    /// publish the grid and ping-pong writes between dependent dispatches.
    public func encode(at time: Double, into command: MTLCommandBuffer) throws {
        encodedSteps = 0
        guard time.isFinite else { return }
        // Immutable staging buffers and queue-ordered copies avoid touching state
        // still owned by an in-flight frame. Rebuild neighbors after slot reuse.
        if !engine.pendingEmissions.isEmpty {
            let indices = engine.pendingEmissions
            let emitted = indices.map { i in
                let p = engine.particles[i]
                return State(positionRadius: SIMD4(Float(p.position.x), Float(p.position.y), Float(p.radius), Float(i % 7)),
                             velocity: SIMD4(Float(p.velocity.dx), Float(p.velocity.dy), 0, Float(radii.firstIndex(of: p.radius)!)))
            }
            let upload = try Self.buffer(emitted, device: device)
            let rebuildUpload = try Self.buffer([iterationGeneration], device: device)
            guard let blit = command.makeBlitCommandEncoder() else { throw Self.failure("Emission encoder unavailable") }
            for (offset, index) in indices.enumerated() {
                blit.copy(from: upload, sourceOffset: offset * MemoryLayout<State>.stride,
                          to: states[current], destinationOffset: index * MemoryLayout<State>.stride, size: MemoryLayout<State>.stride)
            }
            blit.copy(from: rebuildUpload, sourceOffset: 0, to: rebuild, destinationOffset: 0, size: 4)
            blit.endEncoding()
            engine.clearPendingEmissions()
        }
        if clockRevision != engine.clockRevision {
            clockRevision = engine.clockRevision
            previousTime = nil
            accumulatedTime = 0
        }
        guard let previousTime else { self.previousTime = time; return }
        try updateGeometry()
        let accumulated = min(accumulatedTime + max(0, time - previousTime), step * 16)
        let availableSteps = Int((accumulated + 1e-10) / step)
        // At most one 60 Hz frame of work. A slow frame must not amplify
        // dense-contact work by queuing sixteen catch-up substeps.
        let steps = min(4, availableSteps)
        let substeps = engine.integrationSubsteps
        let contactPasses = max(contactIterations, substeps)
        guard steps > 0, engine.activeParticleCount > 0 else {
            self.previousTime = time
            accumulatedTime = accumulated
            return
        }
        guard let encoder = command.makeComputeCommandEncoder() else { throw Self.failure("Compute encoder unavailable") }
        encoder.label = "240 Hz particle physics with travel substeps"
        let bounds = engine.bounds
        let cursor = engine.consumeCursor(at: time)
        var p = Parameters(bounds: SIMD4(Float(bounds.minX), Float(bounds.minY), Float(bounds.maxX), Float(bounds.maxY)),
                           dynamics: SIMD4(Float(engine.gravity + engine.externalAcceleration.dy), Float(step / Double(substeps)), inverseCellSize, skin),
                           counts: SIMD4(UInt32(engine.activeParticleCount), UInt32(bucketCount - 1), counts.x, counts.y),
                           geometry: SIMD4(counts.z, counts.w, 0, 0),
                           limits: SIMD4(Float(engine.maximumSpeed), 0, Float(engine.externalAcceleration.dx), 0),
                           cursorSegment: .zero, cursorMotion: .zero, cursorBounds: .zero)
        if let cursor {
            p.cursorSegment = SIMD4(Float(cursor.start.x), Float(cursor.start.y), Float(cursor.end.x), Float(cursor.end.y))
            p.cursorMotion = SIMD4(Float(cursor.velocity.dx), Float(cursor.velocity.dy), Float(CursorCollider.radius), Float(cursor.inverseLengthSquared))
            p.cursorBounds = SIMD4(Float(cursor.sweepBounds.minX), Float(cursor.sweepBounds.minY), Float(cursor.sweepBounds.maxX), Float(cursor.sweepBounds.maxY))
            // Stationary/just-enabled cursors only need the ordinary circle contact.
            p.limits.w = cursor.inverseLengthSquared > 0 ? 1 : 0
        }
        encoder.setBuffer(heads, offset: 0, index: 2)
        encoder.setBuffer(links, offset: 0, index: 3)
        encoder.setBuffer(shapes, offset: 0, index: 5)
        encoder.setBuffer(edges, offset: 0, index: 6)
        encoder.setBuffer(windows, offset: 0, index: 7)
        encoder.setBuffer(curve, offset: 0, index: 8)
        encoder.setBuffer(rectangles, offset: 0, index: 9)
        encoder.setBuffer(exits, offset: 0, index: 10)
        encoder.setBuffer(neighbors, offset: 0, index: 11)
        encoder.setBuffer(referencePositions, offset: 0, index: 12)
        encoder.setBuffer(rebuild, offset: 0, index: 13)
        encoder.setBuffer(statistics, offset: 0, index: 14)
        func dispatch(_ pipeline: MTLComputePipelineState, count: Int) {
            encoder.setComputePipelineState(pipeline)
            let group = MTLSize(width: ParticleComputeKernels.threadgroupWidth, height: 1, depth: 1)
            encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: group)
            encoder.memoryBarrier(scope: .buffers)
        }
        for _ in 0..<steps {
            // Share the existing contact budget across shorter integration steps.
            // Neighbor caches remain GPU-resident and rebuild only after motion.
            for substep in 0..<substeps {
                let iterations = contactPasses / substeps + (substep < contactPasses % substeps ? 1 : 0)
                p.limits.y = p.dynamics.y / Float(iterations)
                p.geometry.z = collectDiagnostics ? 2 : 0
                p.geometry.w = iterationGeneration
                encoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 4)
                encoder.setBuffer(states[current], offset: 0, index: 0)
                dispatch(integrate, count: engine.activeParticleCount)
                p.limits.w = 0
                for iteration in 0..<iterations {
                    p.geometry.z = (iteration == 0 ? 1 : 0) | (collectDiagnostics ? 2 : 0)
                    p.geometry.w = iterationGeneration
                    encoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 4)
                    encoder.setBuffer(states[current], offset: 0, index: 0)
                    encoder.setBuffer(states[1 - current], offset: 0, index: 1)
                    dispatch(clear, count: bucketCount)
                    dispatch(build, count: engine.activeParticleCount)
                    dispatch(cacheNeighbors, count: engine.activeParticleCount)
                    dispatch(solve, count: engine.activeParticleCount)
                    current = 1 - current
                    iterationGeneration &+= 1
                }
            }
        }
        encoder.endEncoding()
        self.previousTime = time
        // Drop overload debt but retain fractional time for stable cadence.
        accumulatedTime = max(0, accumulated - Double(availableSteps) * step)
        encodedSteps = steps
    }

    /// The caller must wait for its last submitted command before reading.
    public func snapshot() -> [State] {
        Array(UnsafeBufferPointer(start: particleBuffer.contents().assumingMemoryBound(to: State.self), count: engine.activeParticleCount))
    }

    /// Untimed readback after command completion, only enabled by benchmarks.
    public func diagnostics() -> [String: UInt32] {
        guard collectDiagnostics else { return [:] }
        let data = statistics.contents().assumingMemoryBound(to: UInt32.self)
        return ["gridRebuilds": data[0], "overflowedNeighborLists": data[1], "maximumNeighbors": data[2],
                "compressionDespawns": data[3], "invalidStateDespawns": data[4], "workLimitDespawns": data[5]]
    }

    /// Copy counters into a command-owned snapshot so completion callbacks can
    /// read them while subsequent frames continue updating the live counters.
    public func encodeDiagnosticsReadback(into command: MTLCommandBuffer) -> MTLBuffer? {
        guard collectDiagnostics,
              let snapshot = device.makeBuffer(length: statistics.length, options: .storageModeShared),
              let blit = command.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: statistics, sourceOffset: 0, to: snapshot, destinationOffset: 0, size: statistics.length)
        blit.endEncoding()
        return snapshot
    }
}
