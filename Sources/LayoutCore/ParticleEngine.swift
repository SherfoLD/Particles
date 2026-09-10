import Foundation
import CoreGraphics

/// Circle contacts and sequential impulses. No SpriteKit objects enter the physics loop.
public final class Particle {
    public var position: CGPoint
    public var velocity: CGVector
    public let radius: CGFloat

    public init(position: CGPoint, velocity: CGVector = .zero, radius: CGFloat = 3) {
        precondition(radius > 0 && radius.isFinite)
        self.position = position
        self.velocity = velocity
        self.radius = radius
    }
}

public final class ParticleEngine {
    public let particles: [Particle]
    /// Emission scenes reserve storage once and grow the simulated prefix, then
    /// recycle the oldest slot. Rain scenes start with the entire array active.
    public private(set) var activeParticleCount: Int
    public private(set) var pendingEmissions: [Int] = []
    private var nextEmissionIndex = 0
    public let bounds: CGRect
    public var obstacles: [CGRect] = [] {
        didSet {
            guard obstacles != oldValue else { return }
            geometryRevision &+= 1
            colliders = obstacles.filter { !$0.isEmpty && !$0.isNull }.map(CollisionRect.init)
        }
    }
    public var collisionShapes: [CollisionShape] = [] {
        didSet { if collisionShapes != oldValue { geometryRevision &+= 1 } }
    }
    public private(set) var geometryRevision: UInt64 = 0
    public private(set) var clockRevision: UInt64 = 0
    public static let cursorRadius: CGFloat = 8
    /// Display-local cursor tip; nil disables contacts. No geometry invalidation.
    public var cursorPosition: CGPoint? {
        didSet { if cursorPosition == nil { previousCursorSample = nil } }
    }
    private var previousCursorSample: (position: CGPoint, time: TimeInterval)?

    func consumeCursor(at time: TimeInterval) -> CursorCollider? {
        guard let position = cursorPosition, position.x.isFinite, position.y.isFinite else {
            previousCursorSample = nil
            return nil
        }
        let previous = previousCursorSample
        previousCursorSample = (position, time)
        // Resume/enable/display entry starts locally, without a stroke across the screen.
        let duration = previous.map { time - $0.time } ?? 0
        let start = duration > 0 && duration <= 0.1 ? previous!.position : position
        return CursorCollider(start: start, end: position, duration: CGFloat(duration), maximumSpeed: maximumSpeed)
    }
    /// Application windows form one solid region. Resolving them independently
    /// can bounce an embedded particle between overlapping, hidden edges.
    public var windowObstacles: [CGRect] = [] {
        didSet {
            guard windowObstacles != oldValue else { return }
            rebuildWindowColliders()
        }
    }
    /// macOS 27's standard 16-point continuous corner profile. Window Server
    /// supplies bounds; display-covering windows retain square corners.
    public var windowCornerRadius: CGFloat = WindowCornerCurve.defaultRadius {
        didSet { rebuildWindowColliders() }
    }
    // Contiguous solver storage avoids ARC/property exclusivity overhead in contacts.
    // Public Particle objects are synchronized only at the frame boundary.
    private struct State {
        var position: CGPoint
        var velocity: CGVector
        let radius: CGFloat
    }
    private let states: UnsafeMutablePointer<State>
    private let occupiedCells: UnsafeMutablePointer<Int>
    private var occupiedCount = 0
    private var colliders: [CollisionRect] = []
    private var windowColliders: [RoundedWindowCollider] = []
    private let boundary: CollisionRect

    /// Cache Quartz edge extraction outside the hot contact loop.
    private struct CollisionRect {
        let minX: CGFloat
        let maxX: CGFloat
        let minY: CGFloat
        let maxY: CGFloat
        init(_ rect: CGRect) {
            minX = rect.minX
            maxX = rect.maxX
            minY = rect.minY
            maxY = rect.maxY
        }
    }
    public var gravity: CGFloat = -1_800
    public static let defaultMaximumSpeed: CGFloat = 300
    private var speedLimit = ParticleEngine.defaultMaximumSpeed
    /// Points per second, independent of radius. Changes apply on the next step.
    public var maximumSpeed: CGFloat {
        get { speedLimit }
        set { speedLimit = newValue.isFinite ? min(500, max(100, newValue)) : Self.defaultMaximumSpeed }
    }
    private let minimumRadius: CGFloat
    /// Keep travel below half the smallest radius without slowing small balls.
    public var integrationSubsteps: Int {
        max(1, Int(ceil(maximumSpeed * step / (minimumRadius * 0.5))))
    }
    public private(set) var candidateChecks = 0
    private var previousTime: TimeInterval?
    private var accumulatedTime: CGFloat = 0
    private let step: CGFloat = 1 / 240
    private let cellSize: CGFloat
    private var grid: UnsafeMutablePointer<Int>?
    private let next: UnsafeMutablePointer<Int>
    private let columns: Int
    private var rows = 0
    private let gridOrigin: CGPoint

    public init(particles: [Particle], bounds: CGRect, initiallyActive: Bool = true) {
        self.particles = particles
        minimumRadius = particles.map(\.radius).min() ?? 1.5
        activeParticleCount = initiallyActive ? particles.count : 0
        precondition(bounds.width > 0 && bounds.height > 0 && !bounds.isInfinite && !bounds.isNull)
        self.bounds = bounds
        states = .allocate(capacity: max(1, particles.count))
        for i in particles.indices {
            states.advanced(by: i).initialize(to: State(position: particles[i].position, velocity: particles[i].velocity, radius: particles[i].radius))
        }
        occupiedCells = .allocate(capacity: max(1, particles.count))
        boundary = CollisionRect(bounds)
        cellSize = max(1, (particles.map(\.radius).max() ?? 3) * 2)
        next = .allocate(capacity: max(1, particles.count))
        columns = max(5, Int(ceil(bounds.width / cellSize)) + 4)
        gridOrigin = CGPoint(x: bounds.minX - 2 * cellSize, y: bounds.minY - 2 * cellSize)
    }

    deinit {
        states.deinitialize(count: particles.count)
        states.deallocate()
        grid?.deallocate()
        next.deallocate()
        occupiedCells.deallocate()
    }

    /// All particles exist immediately, in loose rows above the display's top.
    /// The open ceiling lets the rows fall into view without an overlapping burst.
    public static func rain(count: Int = 3_000, bounds: CGRect, seed: UInt64 = 42, radius: CGFloat = 1.5) -> ParticleEngine {
        var random = SeededRandom(state: seed)
        precondition(radius > 0 && radius.isFinite && bounds.width >= radius * 2)
        let spacing: CGFloat = radius * 3
        let columns = max(1, Int((bounds.width - 2 * radius) / spacing))
        let particles = (0..<max(0, count)).map { index in
            Particle(position: CGPoint(
                x: bounds.minX + radius + (CGFloat(index % columns) + 0.5) * (bounds.width - 2 * radius) / CGFloat(columns),
                y: bounds.maxY + radius + CGFloat(index / columns) * spacing + random.unit() * 2),
                velocity: CGVector(dx: (random.unit() - 0.5) * 35, dy: -random.unit() * 40), radius: radius)
        }
        return ParticleEngine(particles: particles, bounds: bounds)
    }

    public func resetClock() {
        clockRevision &+= 1
        previousCursorSample = nil
        previousTime = nil
        accumulatedTime = 0
    }

    public static func cannon(bounds: CGRect, capacity: Int = 3_000, radius: CGFloat = 3) -> ParticleEngine {
        let engine = ParticleEngine(particles: (0..<max(1, capacity)).map { _ in
            Particle(position: .zero, radius: radius)
        }, bounds: bounds, initiallyActive: false)
        engine.gravity = -650
        return engine
    }

    public func emit(position: CGPoint, velocity: CGVector) {
        guard !particles.isEmpty else { return }
        let index = nextEmissionIndex
        particles[index].position = position
        particles[index].velocity = velocity
        activeParticleCount = max(activeParticleCount, index + 1)
        // Bounded even if presentation stalls for an extended period.
        if !pendingEmissions.contains(index) { pendingEmissions.append(index) }
        nextEmissionIndex = (index + 1) % particles.count
    }

    public func clearPendingEmissions() { pendingEmissions.removeAll(keepingCapacity: true) }

    /// Geometry query for diagnostics without advancing either solver.
    public func intersectsWindow(at position: CGPoint, radius: CGFloat) -> Bool {
        windowColliders.contains { $0.contains(position, clearance: radius) }
    }

    public func update(at time: TimeInterval) {
        guard time.isFinite else { return }
        guard let previousTime else { self.previousTime = time; return }
        self.previousTime = time
        // Never catch up an entire sleep, display reconfiguration or debugger stop.
        accumulatedTime = min(accumulatedTime + max(0, CGFloat(time - previousTime)), step * 16)
        candidateChecks = 0
        for i in 0..<activeParticleCount {
            states[i].position = particles[i].position
            states[i].velocity = particles[i].velocity
        }
        let substeps = integrationSubsteps
        let contactPasses = max(12, substeps)
        let cursor = accumulatedTime + 1e-10 >= step ? consumeCursor(at: time) : nil
        var sweepCursor = true
        while accumulatedTime + 1e-10 >= step {
            for substep in 0..<substeps {
                let iterations = contactPasses / substeps + (substep < contactPasses % substeps ? 1 : 0)
                simulateStep(step: step / CGFloat(substeps), iterations: iterations, cursor: cursor, sweepCursor: sweepCursor)
                sweepCursor = false
            }
            accumulatedTime -= step
        }
        for i in 0..<activeParticleCount {
            particles[i].position = states[i].position
            particles[i].velocity = states[i].velocity
        }
    }

    private func simulateStep(step: CGFloat, iterations: Int, cursor: CursorCollider?, sweepCursor: Bool) {
        let states = states
        let collisionShapes = collisionShapes
        let colliders = colliders
        let next = next
        let occupiedCells = occupiedCells
        var occupiedCount = occupiedCount
        var checks = 0
        var top = boundary.maxY
        let limit = maximumSpeed
        let limitSquared = limit * limit
        for i in 0..<activeParticleCount {
            var velocity = states[i].velocity
            velocity.dy += gravity * step
            let squaredSpeed = velocity.dx * velocity.dx + velocity.dy * velocity.dy
            if squaredSpeed > limitSquared {
                let scale = limit / sqrt(squaredSpeed)
                velocity.dx *= scale
                velocity.dy *= scale
            }
            states[i].velocity = velocity
            states[i].position.x += velocity.dx * step
            states[i].position.y += velocity.dy * step
            if sweepCursor, let cursor, cursor.inverseLengthSquared > 0 {
                cursor.resolve(position: &states[i].position, velocity: &states[i].velocity, radius: states[i].radius, swept: true)
            }
            top = max(top, states[i].position.y)
        }
        let neededRows = max(5, Int(ceil((top - gridOrigin.y) / cellSize)) + 5)
        if neededRows > rows {
            rows = neededRows
            grid?.deallocate()
            grid = .allocate(capacity: columns * rows)
            grid!.initialize(repeating: -1, count: columns * rows)
            occupiedCount = 0
        }

        let grid = grid!
        for iteration in 0..<iterations {
            // Rebuild after projection; clear only occupied buckets, not pixels.
            for i in 0..<occupiedCount { grid[occupiedCells[i]] = -1 }
            occupiedCount = 0
            for index in 0..<activeParticleCount {
                let cell = cell(at: states[index].position)
                let bucket = cell.y * columns + cell.x
                if grid[bucket] == -1 { occupiedCells[occupiedCount] = bucket; occupiedCount += 1 }
                next[index] = grid[bucket]
                grid[bucket] = index
            }
            for a in 0..<activeParticleCount {
                let cell = cell(at: states[a].position)
                for dy in -1...1 {
                    for dx in -1...1 {
                        var b = grid[(cell.y + dy) * columns + cell.x + dx]
                        while b >= 0 {
                            if b > a {
                                checks += 1
                                resolve(&states[a], &states[b], bounce: iteration == 0)
                            }
                            b = next[b]
                        }
                    }
                }
            }
            for i in 0..<activeParticleCount {
                if let cursor {
                    cursor.resolve(position: &states[i].position, velocity: &states[i].velocity, radius: states[i].radius, swept: false)
                }
                resolveWalls(&states[i], bounce: iteration == 0)
                for shape in collisionShapes { resolve(&states[i], shape: shape, bounce: iteration == 0) }
                for obstacle in colliders { resolve(&states[i], obstacle: obstacle, bounce: iteration == 0) }
                resolveWindows(&states[i], bounce: iteration == 0)
                let velocity = states[i].velocity
                let squaredSpeed = velocity.dx * velocity.dx + velocity.dy * velocity.dy
                if squaredSpeed > limitSquared {
                    let scale = limit / sqrt(squaredSpeed)
                    states[i].velocity.dx *= scale
                    states[i].velocity.dy *= scale
                }
            }
        }
        self.occupiedCount = occupiedCount
        candidateChecks += checks
    }

    @inline(__always)
    private func cell(at point: CGPoint) -> (x: Int, y: Int) {
        // One guard cell on every side makes the nine neighbor lookups branch-free.
        (x: min(columns - 2, max(1, Int(floor((point.x - gridOrigin.x) / cellSize)))),
         y: min(rows - 2, max(1, Int(floor((point.y - gridOrigin.y) / cellSize)))))
    }

    @inline(__always)
    private func resolve(_ a: inout State, _ b: inout State, bounce: Bool) {
        var ap = a.position
        var bp = b.position
        let dx = bp.x - ap.x
        let dy = bp.y - ap.y
        let diameter = a.radius + b.radius
        let distanceSquared = dx * dx + dy * dy
        guard distanceSquared < diameter * diameter else { return }
        let distance = sqrt(distanceSquared)
        let nx = distance > 0.0001 ? dx / distance : 1
        let ny = distance > 0.0001 ? dy / distance : 0
        let ma = 1 / (a.radius * a.radius)
        let mb = 1 / (b.radius * b.radius)
        let inverseMass = ma + mb
        let correction = max(0, diameter - distance - 0.005) * 0.85 / inverseMass
        ap.x -= nx * correction * ma
        ap.y -= ny * correction * ma
        bp.x += nx * correction * mb
        bp.y += ny * correction * mb
        a.position = ap
        b.position = bp
        var av = a.velocity
        var bv = b.velocity
        let vx = bv.dx - av.dx
        let vy = bv.dy - av.dy
        let speed = vx * nx + vy * ny
        guard speed < 0 else { return }
        let restitution: CGFloat = bounce && speed < -45 ? 0.48 : 0
        let impulse = -(1 + restitution) * speed / inverseMass
        let tangentSpeed = -vx * ny + vy * nx
        let friction = min(max(-tangentSpeed / inverseMass, -0.22 * impulse), 0.22 * impulse)
        let ix = nx * impulse - ny * friction
        let iy = ny * impulse + nx * friction
        av.dx -= ix * ma
        av.dy -= iy * ma
        bv.dx += ix * mb
        bv.dy += iy * mb
        a.velocity = av
        b.velocity = bv
    }

    private func resolveWalls(_ particle: inout State, bounce: Bool) {
        let r = particle.radius
        if particle.position.x < boundary.minX + r {
            particle.position.x = boundary.minX + r
            reflect(&particle, nx: 1, ny: 0, bounce: bounce)
        }
        if particle.position.x > boundary.maxX - r {
            particle.position.x = boundary.maxX - r
            reflect(&particle, nx: -1, ny: 0, bounce: bounce)
        }
        if particle.position.y < boundary.minY + r {
            particle.position.y = boundary.minY + r
            reflect(&particle, nx: 0, ny: 1, bounce: bounce)
        }
    }

    private func resolveWindows(_ particle: inout State, bounce: Bool) {
        let p = particle.position, r = particle.radius
        guard let first = windowColliders.first(where: { $0.contains(p, clearance: r) }) else { return }
        let clearance = r + 0.001
        var bestDistance = CGFloat.infinity
        var best: RoundedWindowCollider.Contact?
        func valid(_ point: CGPoint) -> Bool {
            point.x >= boundary.minX + r && point.x <= boundary.maxX - r &&
            point.y >= boundary.minY + r &&
            !windowColliders.contains(where: { $0.contains(point, clearance: r) })
        }
        let nearest = first.nearestBoundary(to: p, clearance: clearance)
        if valid(nearest.point) {
            particle.position = nearest.point
            reflect(&particle, nx: nearest.nx, ny: nearest.ny, bounce: bounce)
            return
        }
        func consider(_ contact: RoundedWindowCollider.Contact) {
            let point = contact.point
            let dx = point.x - p.x, dy = point.y - p.y
            let distance = dx * dx + dy * dy
            guard distance < bestDistance, valid(point) else { return }
            bestDistance = distance
            best = contact
        }
        // At a rounded-corner handoff, each window's individual nearest exit
        // can lie inside the other window. Project against both surfaces to
        // reach their exposed junction before considering distant axis exits.
        // Bound the search so closed gaps still use the recovery path below.
        var local = nearest
        for _ in 0..<24 {
            if valid(local.point) {
                let dx = local.point.x - p.x, dy = local.point.y - p.y
                let length = hypot(dx, dy)
                if length > 0 {
                    consider(RoundedWindowCollider.Contact(point: local.point,
                                                          nx: dx / length, ny: dy / length))
                }
                break
            }
            var projected = false
            for rect in windowColliders where rect.contains(local.point, clearance: r) {
                local = rect.nearestBoundary(to: local.point, clearance: clearance)
                projected = true
            }
            if !projected { break }
        }
        // Find an exposed exit from the entire rounded union, including nested
        // windows and gaps too narrow for a ball. Normals follow the corner arc.
        for rect in windowColliders {
            consider(rect.nearestBoundary(to: p, clearance: clearance))
            if let (top, bottom) = rect.verticalBoundaries(at: p.x, clearance: clearance) {
                consider(top)
                consider(bottom)
            }
            if let (right, left) = rect.horizontalBoundaries(at: p.y, clearance: clearance) {
                consider(right)
                consider(left)
            }
        }
        if let best {
            particle.position = best.point
            reflect(&particle, nx: best.nx, ny: best.ny, bounce: bounce)
        }
    }

    private func rebuildWindowColliders() {
        geometryRevision &+= 1
        let radius = windowCornerRadius.isFinite ? max(0, windowCornerRadius) : WindowCornerCurve.defaultRadius
        windowColliders = windowObstacles.filter {
            !$0.isEmpty && !$0.isNull && !$0.isInfinite &&
            $0.origin.x.isFinite && $0.origin.y.isFinite && $0.width.isFinite && $0.height.isFinite
        }.map { RoundedWindowCollider($0, radius: $0.contains(bounds) ? 0 : radius) }
    }
    private func resolve(_ particle: inout State, obstacle: CollisionRect, bounce: Bool) {
        let p = particle.position
        let r = particle.radius
        let x = min(max(p.x, obstacle.minX), obstacle.maxX)
        let y = min(max(p.y, obstacle.minY), obstacle.maxY)
        let dx = p.x - x
        let dy = p.y - y
        let distanceSquared = dx * dx + dy * dy
        guard distanceSquared < r * r else { return }
        func fits(_ point: CGPoint) -> Bool {
            point.x >= boundary.minX + r && point.x <= boundary.maxX - r && point.y >= boundary.minY + r
        }
        if distanceSquared > 0.00001 {
            let distance = sqrt(distanceSquared)
            let position = CGPoint(x: x + dx / distance * r, y: y + dy / distance * r)
            if fits(position) {
                particle.position = position
                reflect(&particle, nx: dx / distance, ny: dy / distance, bounce: bounce)
                return
            }
        }
        // Recover particles inside moved widgets / an appearing Dock, choosing
        // an exit that doesn't push them through the display's floor or walls.
        let exits: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: p.x, y: obstacle.maxY + r), 0, 1),
            (CGPoint(x: obstacle.maxX + r, y: p.y), 1, 0),
            (CGPoint(x: obstacle.minX - r, y: p.y), -1, 0),
            (CGPoint(x: p.x, y: obstacle.minY - r), 0, -1)
        ]
        if let exit = exits.filter({ fits($0.0) }).min(by: {
            hypot($0.0.x - p.x, $0.0.y - p.y) < hypot($1.0.x - p.x, $1.0.y - p.y)
        }) {
            particle.position = exit.0
            reflect(&particle, nx: exit.1, ny: exit.2, bounce: bounce)
        }
    }

    private func resolve(_ particle: inout State, shape: CollisionShape, bounce: Bool) {
        let p = particle.position, r = particle.radius
        guard p.x > shape.minX - r, p.x < shape.maxX + r,
              p.y > shape.minY - r, p.y < shape.maxY + r else { return }
        let inside = shape.contains(p)
        var bestDistance = CGFloat.infinity
        var best: (CGPoint, CGFloat, CGFloat)?
        for edge in shape.edges {
            let t = min(1, max(0, ((p.x - edge.start.x) * edge.dx + (p.y - edge.start.y) * edge.dy) / edge.lengthSquared))
            let q = CGPoint(x: edge.start.x + t * edge.dx, y: edge.start.y + t * edge.dy)
            let dx = p.x - q.x, dy = p.y - q.y
            let distance = hypot(dx, dy)
            if !inside && distance >= r { continue }
            let nx = inside || distance < 0.00001 ? edge.nx : dx / distance
            let ny = inside || distance < 0.00001 ? edge.ny : dy / distance
            let exit = CGPoint(x: q.x + nx * (r + 0.001), y: q.y + ny * (r + 0.001))
            // Moving shapes must not eject particles through the screen walls.
            guard exit.x >= boundary.minX + r, exit.x <= boundary.maxX - r,
                  exit.y >= boundary.minY + r else { continue }
            let travel = inside ? hypot(exit.x - p.x, exit.y - p.y) : distance
            if travel < bestDistance {
                bestDistance = travel
                best = (exit, nx, ny)
            }
        }
        if let (exit, nx, ny) = best {
            particle.position = exit
            reflect(&particle, nx: nx, ny: ny, bounce: bounce)
        }
    }

    private func reflect(_ particle: inout State, nx: CGFloat, ny: CGFloat, bounce: Bool) {
        var velocity = particle.velocity
        let speed = velocity.dx * nx + velocity.dy * ny
        guard speed < 0 else { return }
        let restitution: CGFloat = bounce && speed < -45 ? 0.42 : 0
        velocity.dx -= nx * (1 + restitution) * speed
        velocity.dy -= ny * (1 + restitution) * speed
        let tangent = -velocity.dx * ny + velocity.dy * nx
        let friction = min(abs(tangent), -speed * 0.22) * (tangent < 0 ? -1.0 : 1.0)
        velocity.dx += ny * friction
        velocity.dy -= nx * friction
        particle.velocity = velocity
    }
}

private struct SeededRandom {
    var state: UInt64
    mutating func unit() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 11) / CGFloat(UInt64.max >> 11)
    }
}
