import Foundation
import CoreGraphics
#if SWIFT_PACKAGE
import LayoutCore
#endif

/// Shared timing summaries, JSON output and untimed simulation diagnostics.
enum PerformanceReport {
    static func summary(_ samples: [Double]) -> [String: Double] {
        guard !samples.isEmpty else { return [:] }
        let sorted = samples.sorted()
        return ["mean": samples.reduce(0, +) / Double(samples.count),
                "p50": sorted[(sorted.count - 1) / 2],
                "p95": sorted[Int(Double(sorted.count - 1) * 0.95)],
                "p99": sorted[Int(Double(sorted.count - 1) * 0.99)], "max": sorted.last!]
    }

    static func printJSON(_ report: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
    }

    /// Untimed benchmark diagnostics: a faster solver must still retain balls,
    /// respect the container, and form piles rather than collapse into overlaps.
    static func health(_ particles: [Particle], engine: ParticleEngine) -> [String: Double] {
        let cellSize = (particles.map(\.radius).max() ?? 1.5) * 2
        var grid: [SIMD2<Int>: [Int]] = [:]
        var overlaps: [Double] = []
        var nonfinite = 0, walls = 0, windows = 0, clearance = 0
        for (i, a) in particles.enumerated() {
            guard a.position.x.isFinite, a.position.y.isFinite, a.velocity.dx.isFinite, a.velocity.dy.isFinite else {
                nonfinite += 1; continue
            }
            if a.position.x < engine.bounds.minX + a.radius - 0.001 ||
                a.position.x > engine.bounds.maxX - a.radius + 0.001 ||
                a.position.y < engine.bounds.minY + a.radius - 0.001 { walls += 1 }
            if engine.intersectsWindow(at: a.position, radius: 0) { windows += 1 }
            if engine.intersectsWindow(at: a.position, radius: max(0, a.radius - 0.001)) { clearance += 1 }
            let cell = SIMD2(Int(floor(a.position.x / cellSize)), Int(floor(a.position.y / cellSize)))
            for y in -1...1 { for x in -1...1 {
                for j in grid[cell &+ SIMD2(x, y)] ?? [] {
                    let b = particles[j]
                    let overlap = a.radius + b.radius - hypot(a.position.x - b.position.x, a.position.y - b.position.y)
                    if overlap > 0 { overlaps.append(Double(overlap / (a.radius + b.radius))) }
                }
            } }
            grid[cell, default: []].append(i)
        }
        let speeds = particles.map { hypot(Double($0.velocity.dx), Double($0.velocity.dy)) }.filter(\.isFinite)
        return ["nonfiniteParticles": Double(nonfinite), "wallViolations": Double(walls), "windowCenterViolations": Double(windows),
                "p95Speed": summary(speeds)["p95"] ?? 0, "maxSpeed": speeds.max() ?? 0,
                "windowClearanceViolations": Double(clearance),
                "overlappingPairs": Double(overlaps.count), "maxOverlapFraction": overlaps.max() ?? 0,
                "p95OverlapFraction": summary(overlaps)["p95"] ?? 0]
    }
}
