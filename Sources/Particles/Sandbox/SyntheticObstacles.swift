import Foundation
import CoreGraphics
#if SWIFT_PACKAGE
import LayoutCore
#endif

/// Serializable geometry is independent of polling and motion. Register a new
/// named type (optionally inheriting another type) without changing the scheduler.
struct SyntheticObstacleType: Codable {
    var id: String
    var base: String?
    var shape: String?
    var hz: Double?
    var delayMs: Double?
    var radius: Double?
    var points: [[Double]]?
}

struct SyntheticKeyframe: Codable {
    var at: Double
    var frame: [Double]
}

struct SyntheticObstacleSpec: Codable {
    var id: String
    var type: String
    var frame: [Double]
    var hz: Double?
    var delayMs: Double?
    var spawnAt: Double = 0
    var removeAt: Double?
    var keyframes: [SyntheticKeyframe]?

    enum CodingKeys: String, CodingKey { case id, type, frame, hz, delayMs, spawnAt, removeAt, keyframes }
    init(id: String, type: String, frame: [Double], hz: Double? = nil, delayMs: Double? = nil,
         spawnAt: Double = 0, removeAt: Double? = nil, keyframes: [SyntheticKeyframe]? = nil) {
        self.id = id; self.type = type; self.frame = frame; self.hz = hz; self.delayMs = delayMs
        self.spawnAt = spawnAt; self.removeAt = removeAt; self.keyframes = keyframes
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); type = try c.decode(String.self, forKey: .type)
        frame = try c.decode([Double].self, forKey: .frame)
        hz = try c.decodeIfPresent(Double.self, forKey: .hz)
        delayMs = try c.decodeIfPresent(Double.self, forKey: .delayMs)
        spawnAt = try c.decodeIfPresent(Double.self, forKey: .spawnAt) ?? 0
        removeAt = try c.decodeIfPresent(Double.self, forKey: .removeAt)
        keyframes = try c.decodeIfPresent([SyntheticKeyframe].self, forKey: .keyframes)
    }
}

struct SyntheticScenario: Codable {
    var width: Double = 1200
    var height: Double = 760
    var duration: Double = 12
    var types: [SyntheticObstacleType] = []
    var obstacles: [SyntheticObstacleSpec]

    enum CodingKeys: String, CodingKey { case width, height, duration, types, obstacles }
    init(obstacles: [SyntheticObstacleSpec]) { self.obstacles = obstacles }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 1200
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 760
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 12
        types = try c.decodeIfPresent([SyntheticObstacleType].self, forKey: .types) ?? []
        obstacles = try c.decode([SyntheticObstacleSpec].self, forKey: .obstacles)
    }
    static func argument(_ name: String) throws -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: name) else { return nil }
        guard i + 1 < CommandLine.arguments.count, !CommandLine.arguments[i + 1].hasPrefix("--") else {
            throw SyntheticError.invalid("Missing value for \(name)")
        }
        return CommandLine.arguments[i + 1]
    }
    static func fromArguments() throws -> SyntheticScenario? {
        guard let path = try argument("--scenario") else { return nil }
        guard !SyntheticFixtures.isSelected else {
            throw SyntheticError.invalid("Use --scenario without legacy fixture flags")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    static var playground: Self {
        Self(obstacles: [
            .init(id: "widget-1", type: "widget", frame: [100, 390, 200, 160]),
            .init(id: "folder-1", type: "folder", frame: [380, 440, 80, 80]),
            .init(id: "icon-1", type: "icon", frame: [540, 440, 72, 88]),
            .init(id: "window-1", type: "window", frame: [720, 240, 350, 220]),
            .init(id: "dock-1", type: "dock", frame: [300, 5, 600, 65])
        ])
    }
}

enum SyntheticError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct SyntheticTypeRegistry {
    private(set) var types: [String: SyntheticObstacleType] = [:]
    var names: [String] {
        let builtins = ["widget", "folder", "icon", "window", "dock"]
        return builtins + types.keys.filter { !builtins.contains($0) }.sorted()
    }
    init(_ additions: [SyntheticObstacleType]) throws {
        for (id, hz) in [("widget", 1.0), ("folder", 1), ("icon", 1), ("window", 60), ("dock", 10)] {
            types[id] = .init(id: id, shape: id, hz: hz, delayMs: 0)
        }
        var pending = additions
        guard Set(additions.map(\.id)).count == additions.count else { throw SyntheticError.invalid("Duplicate type IDs") }
        while !pending.isEmpty {
            let oldCount = pending.count
            for definition in pending {
                guard types[definition.id] == nil else { throw SyntheticError.invalid("Type already exists: \(definition.id)") }
                if let base = definition.base, types[base] == nil { continue }
                var resolved = definition.base.flatMap { types[$0] } ?? .init(id: definition.id, hz: 1, delayMs: 0)
                resolved.id = definition.id; resolved.base = definition.base
                if let shape = definition.shape { resolved.shape = shape }
                if let hz = definition.hz { resolved.hz = hz }
                if let delay = definition.delayMs { resolved.delayMs = delay }
                if let radius = definition.radius { resolved.radius = radius }
                if let points = definition.points { resolved.points = points }
                try Self.validate(resolved)
                types[definition.id] = resolved
                pending.removeAll { $0.id == definition.id }
            }
            guard pending.count < oldCount else { throw SyntheticError.invalid("Unknown or cyclic base types: \(pending.map(\.id))") }
        }
    }
    static func validateTiming(hz: Double, delay: Double) throws {
        guard hz.isFinite, (0.1...240).contains(hz), delay.isFinite, (0...10_000).contains(delay) else {
            throw SyntheticError.invalid("Hz must be 0.1–240 and delay must be 0–10000 ms")
        }
    }
    private static func validate(_ type: SyntheticObstacleType) throws {
        try validateTiming(hz: type.hz ?? 1, delay: type.delayMs ?? 0)
        guard let shape = type.shape, ["widget", "folder", "icon", "window", "dock", "rectangle", "roundedRect", "ellipse", "polygon"].contains(shape) else {
            throw SyntheticError.invalid("Unknown shape for type \(type.id)")
        }
        if let r = type.radius, !r.isFinite || r < 0 { throw SyntheticError.invalid("Invalid radius for \(type.id)") }
        if shape == "polygon" {
            guard let points = type.points, (3...96).contains(points.count),
                  points.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }) else {
                throw SyntheticError.invalid("Polygon \(type.id) needs 3–96 normalized [x,y] points")
            }
            let p = points.map { CGPoint(x: $0[0], y: $0[1]) }
            let area = p.indices.reduce(0.0) { sum, i in
                let b = p[(i + 1) % p.count]; return sum + p[i].x * b.y - b.x * p[i].y
            }
            func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
                (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            }
            guard abs(area) > 1e-8 else { throw SyntheticError.invalid("Polygon \(type.id) has zero area") }
            for i in p.indices {
                let a = p[i], b = p[(i + 1) % p.count]
                guard hypot(a.x - b.x, a.y - b.y) > 1e-8 else { throw SyntheticError.invalid("Duplicate polygon vertices") }
                for j in p.indices where j > i + 1 && !(i == 0 && j == p.count - 1) {
                    let c = p[j], d = p[(j + 1) % p.count]
                    if max(a.x,b.x) < min(c.x,d.x) || max(c.x,d.x) < min(a.x,b.x) ||
                        max(a.y,b.y) < min(c.y,d.y) || max(c.y,d.y) < min(a.y,b.y) { continue }
                    if cross(a,b,c) * cross(a,b,d) <= 0 && cross(c,d,a) * cross(c,d,b) <= 0 {
                        throw SyntheticError.invalid("Polygon \(type.id) intersects itself")
                    }
                }
            }
        }
    }
    func geometry(type name: String, frame: CGRect) -> SyntheticGeometry {
        let type = types[name]!
        switch type.shape! {
        case "window": return .window(frame)
        case "dock": return .shape(DockGeometry.collisionShape(in: frame))
        case "widget": return .shape(.roundedRect(frame.insetBy(dx: 8, dy: 8), radius: 26))
        case "folder": return .shape(DesktopItem.folderCollisionShape(in: frame))
        case "rectangle": return .shape(.roundedRect(frame, radius: 0))
        case "roundedRect": return .shape(.roundedRect(frame, radius: type.radius ?? 16))
        case "ellipse":
            return .shape(CollisionShape(vertices: (0..<48).map { i in
                let a = Double(i) * .pi * 2 / 48
                return CGPoint(x: frame.midX + cos(a) * frame.width / 2, y: frame.midY + sin(a) * frame.height / 2)
            }))
        default:
            let points = type.shape == "icon"
                ? [[0.15, 0.05], [0.85, 0.05], [0.85, 0.72], [0.62, 0.95], [0.15, 0.95]] : type.points!
            return .shape(CollisionShape(vertices: points.map { CGPoint(x: frame.minX + $0[0] * frame.width, y: frame.minY + $0[1] * frame.height) }))
        }
    }
}

enum SyntheticGeometry {
    case window(CGRect)
    case shape(CollisionShape)
    var path: CGPath {
        switch self {
        case .window(let rect): return WindowCornerCurve.path(in: rect, radius: WindowCornerCurve.defaultRadius)
        case .shape(let shape): return shape.path
        }
    }
}

/// Source motion, acquisition cadence, delivery latency, and renderer cadence
/// have separate clocks. The physics engine sees only the last delivered sample.
@MainActor
final class SyntheticWorld {
    struct Observation { var sampledAt: Double; var frame: CGRect? }
    final class Obstacle {
        var spec: SyntheticObstacleSpec
        var hz: Double
        var delayMs: Double
        var pollOrigin: Double = 0
        var pollIndex = 0
        var nextPoll: Double { pollOrigin + Double(pollIndex) / hz }
        var pending: [Observation] = []
        var delivered: Observation?
        var geometry: SyntheticGeometry?
        var geometryFrame: CGRect?
        var manualFrames: [(Double, CGRect)] = []
        var removedAt: Double?
        var polls = 0, deliveries = 0, skippedPolls = 0
        var ages: [Double] = [], errors: [Double] = []
        init(_ spec: SyntheticObstacleSpec, type: SyntheticObstacleType) {
            self.spec = spec; hz = spec.hz ?? type.hz!; delayMs = spec.delayMs ?? type.delayMs!
        }
        func frame(at time: Double) -> CGRect? {
            guard time + 1e-9 >= spec.spawnAt, time + 1e-9 < min(removedAt ?? .infinity, spec.removeAt ?? .infinity) else { return nil }
            if let manual = manualFrames.last(where: { $0.0 <= time + 1e-9 }) { return manual.1 }
            var previous = SyntheticKeyframe(at: spec.spawnAt, frame: spec.frame)
            for key in spec.keyframes ?? [] {
                if time < key.at {
                    let t = max(0, (time - previous.at) / (key.at - previous.at))
                    return Self.rect(zip(previous.frame, key.frame).map { $0 + ($1 - $0) * t })
                }
                previous = key
            }
            return Self.rect(previous.frame)
        }
        static func rect(_ values: [Double]) -> CGRect { CGRect(x: values[0], y: values[1], width: values[2], height: values[3]) }
    }
    let scenario: SyntheticScenario
    let registry: SyntheticTypeRegistry
    private(set) var obstacles: [Obstacle] = []
    private(set) var time: Double = 0
    private(set) var revision = 0
    private var nextID = 1
    private var previousShapes: [CollisionShape] = []
    private var previousWindows: [CGRect] = []

    init(_ scenario: SyntheticScenario) throws {
        guard scenario.width.isFinite, scenario.height.isFinite, (100...4096).contains(scenario.width),
              (100...4096).contains(scenario.height), scenario.duration.isFinite, (0.1...3600).contains(scenario.duration),
              scenario.obstacles.count <= 256 else { throw SyntheticError.invalid("Invalid scenario size, duration, or obstacle count (maximum 256)") }
        self.scenario = scenario; registry = try SyntheticTypeRegistry(scenario.types)
        guard Set(scenario.obstacles.map(\.id)).count == scenario.obstacles.count else { throw SyntheticError.invalid("Duplicate obstacle IDs") }
        for spec in scenario.obstacles { try append(spec) }
    }
    private func append(_ spec: SyntheticObstacleSpec) throws {
        guard !spec.id.isEmpty, let type = registry.types[spec.type] else { throw SyntheticError.invalid("Unknown obstacle type: \(spec.type)") }
        try SyntheticTypeRegistry.validateTiming(hz: spec.hz ?? type.hz!, delay: spec.delayMs ?? type.delayMs!)
        func validFrame(_ f: [Double]) -> Bool {
            f.count == 4 && f.allSatisfy { $0.isFinite && abs($0) <= 100_000 } && f[2] >= 20 && f[3] >= 20 && f[2] <= 4096 && f[3] <= 4096
        }
        guard validFrame(spec.frame), spec.spawnAt.isFinite, spec.spawnAt >= 0,
              spec.removeAt == nil || (spec.removeAt!.isFinite && spec.removeAt! > spec.spawnAt) else {
            throw SyntheticError.invalid("Invalid frame or lifetime for \(spec.id)")
        }
        var last = spec.spawnAt
        for key in spec.keyframes ?? [] {
            guard key.at.isFinite, key.at > last, validFrame(key.frame) else { throw SyntheticError.invalid("Keyframes for \(spec.id) must have increasing times after spawnAt and valid frames") }
            last = key.at
        }
        let obstacle = Obstacle(spec, type: type)
        // All initial obstacles share the source clock, including future spawns.
        obstacle.pollOrigin = time
        obstacles.append(obstacle)
    }
    @discardableResult
    func spawn(type: String, frame: CGRect, hz: Double, delayMs: Double) throws -> String {
        guard obstacles.count < 256 else { throw SyntheticError.invalid("Maximum 256 obstacles per run; restart to clear the history") }
        var id: String
        repeat { id = "\(type)-\(nextID)"; nextID += 1 } while obstacles.contains { $0.spec.id == id }
        try append(.init(id: id, type: type, frame: [frame.minX, frame.minY, frame.width, frame.height], hz: hz, delayMs: delayMs, spawnAt: time))
        return id
    }
    func move(id: String, to frame: CGRect, at eventTime: Double? = nil) {
        let eventTime = eventTime ?? time
        guard let obstacle = obstacles.first(where: { $0.spec.id == id }), obstacle.frame(at: eventTime) != nil else { return }
        obstacle.manualFrames.append((eventTime, frame))
    }
    func remove(id: String) { obstacles.first { $0.spec.id == id }?.removedAt = time }

    func setTiming(id: String, hz: Double, delayMs: Double) throws {
        try SyntheticTypeRegistry.validateTiming(hz: hz, delay: delayMs)
        guard let obstacle = obstacles.first(where: { $0.spec.id == id }) else { return }
        obstacle.hz = hz; obstacle.delayMs = delayMs
        obstacle.spec.hz = hz; obstacle.spec.delayMs = delayMs
        obstacle.pending.removeAll(); obstacle.pollOrigin = time; obstacle.pollIndex = 0
    }

    func advance(to time: Double, engine: ParticleEngine) {
        self.time = time
        var shapes: [CollisionShape] = [], windows: [CGRect] = []
        for obstacle in obstacles {
            let interval = 1 / obstacle.hz
            // A suspended live view doesn't accumulate unbounded catch-up work.
            // Deterministic offscreen frames do not skip scheduled polls.
            let due = max(0, floor((time - obstacle.nextPoll + 1e-9) / interval) + 1)
            if due > 512 {
                let skipped = Int(due) - 512
                obstacle.pollIndex += skipped; obstacle.skippedPolls += skipped
            }
            while obstacle.nextPoll <= time + 1e-9 {
                let sampled = obstacle.nextPoll
                obstacle.pending.append(.init(sampledAt: sampled, frame: obstacle.frame(at: sampled)))
                obstacle.polls += 1; obstacle.pollIndex += 1
            }
            let ready = obstacle.pending.prefix { $0.sampledAt + obstacle.delayMs / 1000 <= time + 1e-9 }
            if let sample = ready.last { obstacle.delivered = sample; obstacle.deliveries += ready.count }
            obstacle.pending.removeFirst(ready.count)
            // Keep only the manual position needed by future source samples.
            if obstacle.manualFrames.count > 1 {
                obstacle.manualFrames = [obstacle.manualFrames.last!]
            }
            if let sample = obstacle.delivered, let frame = sample.frame {
                if obstacle.geometryFrame != frame {
                    obstacle.geometry = registry.geometry(type: obstacle.spec.type, frame: frame)
                    obstacle.geometryFrame = frame
                }
                switch obstacle.geometry! {
                case .shape(let shape): shapes.append(shape)
                case .window(let rect): windows.append(rect)
                }
                obstacle.ages.append(max(0, (time - sample.sampledAt) * 1000))
                if let source = obstacle.frame(at: time) { obstacle.errors.append(hypot(source.midX - frame.midX, source.midY - frame.midY)) }
                if obstacle.ages.count > 16_384 { obstacle.ages.removeFirst(8192) }
                if obstacle.errors.count > 16_384 { obstacle.errors.removeFirst(8192) }
            }
        }
        if shapes != previousShapes || windows != previousWindows {
            engine.collisionShapes = shapes; engine.windowObstacles = windows
            previousShapes = shapes; previousWindows = windows; revision += 1
        }
    }
    func report() -> [String: Any] {
        ["time": time, "geometryRevisions": revision, "obstacles": obstacles.map { o -> [String: Any] in
            func frame(_ f: CGRect?) -> Any { f.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? NSNull() as Any }
            return ["id": o.spec.id, "type": o.spec.type, "hz": o.hz, "delayMs": o.delayMs,
                    "polls": o.polls, "deliveries": o.deliveries, "skippedPolls": o.skippedPolls,
                    "pendingSamples": o.pending.count, "sourceFrame": frame(o.frame(at: time)),
                    "collisionFrame": frame(o.delivered?.frame), "sampleAgeMs": PerformanceReport.summary(o.ages),
                    "positionErrorPoints": PerformanceReport.summary(o.errors)]
        }]
    }

    func currentSample() -> [String: Any] {
        ["geometryRevisions": revision, "obstacles": obstacles.map { o -> [String: Any] in
            func frame(_ f: CGRect?) -> Any { f.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? NSNull() as Any }
            return ["id": o.spec.id, "sourceFrame": frame(o.frame(at: time)),
                    "collisionFrame": frame(o.delivered?.frame), "sampledAt": o.delivered.map { $0.sampledAt } ?? NSNull() as Any]
        }]
    }
}

/// Explicit opt-in JSONL output. Bounded live summaries are written once per
/// second; offscreen runs write synchronized frame samples outside timed work.
final class SyntheticLog {
    private let handle: FileHandle
    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw SyntheticError.invalid("Cannot create log: \(path)")
        }
        handle = try FileHandle(forWritingTo: url)
    }
    static func fromArguments() throws -> SyntheticLog? {
        try SyntheticScenario.argument("--sandbox-log").map { try SyntheticLog(path: $0) }
    }
    func write(_ report: [String: Any]) throws {
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) + Data([10]))
    }
    func close() throws { try handle.close() }
}
