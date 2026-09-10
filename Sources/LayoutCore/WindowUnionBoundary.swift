import CoreGraphics

/// Exposed edges of the ball-expanded window union. Built on geometry changes,
/// not for each ball/contact iteration. Convex clipping also removes exits
/// beyond the screen walls and floor. Straight contacts still use exact curves.
enum WindowUnionBoundary {
    private struct Segment {
        var a: CGPoint
        var b: CGPoint
        var normal: CGVector
    }
    private struct Polygon {
        var segments: [Segment]
        var bounds: CGRect
        var collider: RoundedWindowCollider
    }

    static func segments(windows: [CGRect], cornerRadius: CGFloat, ballRadius: CGFloat, bounds: CGRect) -> [SIMD4<Float>] {
        let clearance = ballRadius + 0.004
        let polygons = windows.compactMap { rect -> Polygon? in
            let radius = WindowCornerCurve.clampedRadius(rect.contains(bounds) ? 0 : cornerRadius, in: rect)
            var points: [CGPoint] = []
            if radius == 0 {
                points = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                          CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            } else {
                for corner in 0..<4 {
                    let sx: CGFloat = corner < 2 ? 1 : -1
                    let sy: CGFloat = corner == 0 || corner == 3 ? 1 : -1
                    let samples = corner.isMultiple(of: 2) ? WindowCornerCurve.points : Array(WindowCornerCurve.points.reversed())
                    points += samples.map { CGPoint(x: rect.midX + sx * (rect.width / 2 - $0.x * radius),
                                                    y: rect.midY + sy * (rect.height / 2 - $0.y * radius)) }
                }
                points.reverse() // CCW, outward normal on the right of each edge.
            }
            // Clamping a corner to half a narrow window can collapse a straight
            // edge. Remove duplicate endpoints before forming unit normals.
            var distinct: [CGPoint] = []
            for point in points {
                if let last = distinct.last, hypot(last.x - point.x, last.y - point.y) < 1e-10 { continue }
                distinct.append(point)
            }
            if let first = distinct.first, let last = distinct.last,
               hypot(first.x - last.x, first.y - last.y) < 1e-10 { distinct.removeLast() }
            guard distinct.count >= 3 else { return nil }
            points = distinct
            var normals: [CGVector] = []
            for i in points.indices {
                let a = points[i], b = points[(i + 1) % points.count]
                let dx = b.x - a.x, dy = b.y - a.y, length = hypot(dx, dy)
                normals.append(CGVector(dx: dy / length, dy: -dx / length))
            }
            var expanded: [CGPoint] = []
            for i in points.indices {
                let a = normals[(i + points.count - 1) % points.count], b = normals[i], v = points[i]
                let cosine = a.dx * b.dx + a.dy * b.dy
                if cosine > 0.995 {
                    let scale = clearance / (1 + cosine)
                    expanded.append(CGPoint(x: v.x + (a.dx + b.dx) * scale, y: v.y + (a.dy + b.dy) * scale))
                } else {
                    let start = atan2(a.dy, a.dx)
                    var angle = atan2(b.dy, b.dx) - start
                    if angle < 0 { angle += 2 * .pi }
                    let steps = max(1, Int(ceil(angle / 0.08)))
                    // Circumscribed chords keep the true circular clearance.
                    let offset = clearance / cos(angle / CGFloat(steps) / 2)
                    for k in 0...steps {
                        let t = start + angle * CGFloat(k) / CGFloat(steps)
                        expanded.append(CGPoint(x: v.x + cos(t) * offset, y: v.y + sin(t) * offset))
                    }
                }
            }
            let segments = expanded.indices.compactMap { i -> Segment? in
                let a = expanded[i], b = expanded[(i + 1) % expanded.count]
                let dx = b.x - a.x, dy = b.y - a.y
                guard dx * dx + dy * dy > 1e-16 else { return nil }
                return Segment(a: a, b: b, normal: CGVector(dx: dy, dy: -dx))
            }
            return Polygon(segments: segments, bounds: rect.insetBy(dx: -clearance * 1.01, dy: -clearance * 1.01),
                           collider: RoundedWindowCollider(rect, radius: radius))
        }
        var result: [SIMD4<Float>] = []
        for (index, polygon) in polygons.enumerated() {
            for edge in polygon.segments {
                let dx = edge.b.x - edge.a.x, dy = edge.b.y - edge.a.y
                var visible: [(CGFloat, CGFloat)] = [(0, 1)]
                // Clip against the three container half-planes.
                for (distance, slope) in [(bounds.minX + ballRadius - edge.a.x, -dx),
                                          (edge.a.x - bounds.maxX + ballRadius, dx),
                                          (bounds.minY + ballRadius - edge.a.y, -dy)] {
                    guard let interval = visible.first else { break }
                    var low = interval.0, high = interval.1
                    if abs(slope) < 1e-12 { if distance > 0 { visible = [] } }
                    else {
                        let t = -distance / slope
                        if slope > 0 { high = min(high, t) } else { low = max(low, t) }
                        visible = low < high ? [(low, high)] : []
                    }
                }
                let segmentBounds = CGRect(x: min(edge.a.x, edge.b.x), y: min(edge.a.y, edge.b.y),
                                           width: abs(dx), height: abs(dy)).insetBy(dx: -0.0001, dy: -0.0001)
                for (otherIndex, other) in polygons.enumerated() where otherIndex != index {
                    if visible.isEmpty { break }
                    if !segmentBounds.intersects(other.bounds) { continue }
                    // Convexity makes two inside endpoints a complete rejection.
                    // Most hidden edges lie deep in another window's straight
                    // region, so they need no scan through its corner planes.
                    if other.collider.contains(edge.a, clearance: clearance - 0.0001),
                       other.collider.contains(edge.b, clearance: clearance - 0.0001) {
                        visible.removeAll(keepingCapacity: true)
                        break
                    }
                    var low: CGFloat = 0, high: CGFloat = 1
                    for clip in other.segments {
                        let distance = (edge.a.x - clip.a.x) * clip.normal.dx + (edge.a.y - clip.a.y) * clip.normal.dy
                        let slope = dx * clip.normal.dx + dy * clip.normal.dy
                        if abs(slope) < 1e-12 {
                            if distance > 1e-9 { high = -1; break }
                            // Coincident outward faces have one owner. Removing
                            // both would punch a hole in the recovery contour.
                            if abs(distance) <= 1e-9 && otherIndex > index &&
                                edge.normal.dx * clip.normal.dx + edge.normal.dy * clip.normal.dy > 0 {
                                high = -1; break
                            }
                        } else {
                            let t = -distance / slope
                            if slope > 0 { high = min(high, t) } else { low = max(low, t) }
                        }
                        if low >= high { break }
                    }
                    if low < high {
                        visible = visible.flatMap { a, b -> [(CGFloat, CGFloat)] in
                            if high <= a || low >= b { return [(a, b)] }
                            var parts: [(CGFloat, CGFloat)] = []
                            if a < low { parts.append((a, min(b, low))) }
                            if b > high { parts.append((max(a, high), b)) }
                            return parts
                        }
                    }
                }
                let length = hypot(dx, dy)
                for (a, b) in visible {
                    result.append(SIMD4(Float(edge.a.x + a * dx), Float(edge.a.y + a * dy), Float((b-a)*dx), Float((b-a)*dy)))
                    result.append(SIMD4(Float(dy / length), Float(-dx / length), 0, 0))
                }
            }
        }
        return result
    }
}
