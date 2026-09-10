import Foundation
import CoreGraphics

/// A simple, counterclockwise outline shared by the solver and debug renderer.
/// Concave outlines (such as a folder tab) are supported without internal seams.
public struct CollisionShape: Equatable, Sendable {
    public let vertices: [CGPoint]
    public let bounds: CGRect
    let minX: CGFloat
    let maxX: CGFloat
    let minY: CGFloat
    let maxY: CGFloat
    let edges: [Edge]

    struct Edge: Equatable, Sendable {
        let start: CGPoint
        let dx: CGFloat
        let dy: CGFloat
        let lengthSquared: CGFloat
        let nx: CGFloat
        let ny: CGFloat
    }

    public init(vertices: [CGPoint]) {
        precondition(vertices.count >= 3 && vertices.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let area = vertices.indices.reduce(CGFloat.zero) { total, i in
            let a = vertices[i], b = vertices[(i + 1) % vertices.count]
            return total + a.x * b.y - b.x * a.y
        }
        let points = area < 0 ? Array(vertices.reversed()) : vertices
        self.vertices = points
        let xs = points.map(\.x), ys = points.map(\.y)
        bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        minX = bounds.minX; maxX = bounds.maxX; minY = bounds.minY; maxY = bounds.maxY
        edges = points.indices.compactMap { i in
            let a = points[i], b = points[(i + 1) % points.count]
            let dx = b.x - a.x, dy = b.y - a.y
            let squared = dx * dx + dy * dy
            guard squared > 1e-12 else { return nil }
            let length = sqrt(squared)
            return Edge(start: a, dx: dx, dy: dy, lengthSquared: squared, nx: dy / length, ny: -dx / length)
        }
    }

    /// Continuous corners ease into the straight edges of the macOS Dock.
    /// Share the cached native profile with window geometry and debug drawing.
    public static func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CollisionShape {
        CollisionShape(vertices: WindowCornerCurve.vertices(in: rect, radius: radius))
    }

    public static func roundedRect(_ rect: CGRect, radius: CGFloat) -> CollisionShape {
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        if r == 0 {
            return CollisionShape(vertices: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                                              CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)])
        }
        var points: [CGPoint] = []
        let centers = [CGPoint(x: rect.maxX - r, y: rect.minY + r), CGPoint(x: rect.maxX - r, y: rect.maxY - r),
                       CGPoint(x: rect.minX + r, y: rect.maxY - r), CGPoint(x: rect.minX + r, y: rect.minY + r)]
        for corner in 0..<4 {
            for step in 0...8 {
                let angle = CGFloat(corner - 1) * .pi / 2 + CGFloat(step) * .pi / 16
                points.append(CGPoint(x: centers[corner].x + cos(angle) * r, y: centers[corner].y + sin(angle) * r))
            }
        }
        return CollisionShape(vertices: points)
    }

    public var path: CGPath {
        let path = CGMutablePath()
        path.addLines(between: vertices)
        path.closeSubpath()
        return path
    }

    public func contains(_ p: CGPoint) -> Bool {
        var inside = false
        for edge in edges {
            let endY = edge.start.y + edge.dy
            if (edge.start.y > p.y) != (endY > p.y),
               p.x < edge.start.x + (p.y - edge.start.y) * edge.dx / edge.dy { inside.toggle() }
        }
        return inside
    }

    public func intersectsCircle(at point: CGPoint, radius: CGFloat) -> Bool {
        guard bounds.insetBy(dx: -radius, dy: -radius).contains(point) else { return false }
        if contains(point) { return true }
        return edges.contains { edge in
            let t = min(1, max(0, ((point.x - edge.start.x) * edge.dx + (point.y - edge.start.y) * edge.dy) / edge.lengthSquared))
            return hypot(point.x - edge.start.x - t * edge.dx, point.y - edge.start.y - t * edge.dy) <= radius
        }
    }

    /// Translation preserves winding, lengths and normals; do not rebuild them.
    public func translated(by offset: CGPoint) -> CollisionShape {
        CollisionShape(translating: self, by: offset)
    }

    private init(translating shape: CollisionShape, by offset: CGPoint) {
        vertices = shape.vertices.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
        bounds = shape.bounds.offsetBy(dx: offset.x, dy: offset.y)
        minX = bounds.minX; maxX = bounds.maxX; minY = bounds.minY; maxY = bounds.maxY
        edges = shape.edges.map {
            Edge(start: CGPoint(x: $0.start.x + offset.x, y: $0.start.y + offset.y),
                 dx: $0.dx, dy: $0.dy, lengthSquared: $0.lengthSquared, nx: $0.nx, ny: $0.ny)
        }
    }

    /// Test a translated outline without allocating vertices or rebuilding edges.
    /// Works with concave desktop outlines as well as the cannon's convex parts.
    public func intersects(_ other: CollisionShape, offsetBy offset: CGPoint = .zero) -> Bool {
        guard bounds.intersects(other.bounds.offsetBy(dx: offset.x, dy: offset.y)) else { return false }
        // Usually the translated cannon part is inside a much larger window.
        // Test its vertices first instead of walking every window corner against it.
        if other.vertices.contains(where: { contains(CGPoint(x: $0.x + offset.x, y: $0.y + offset.y)) }) ||
            vertices.contains(where: { other.contains(CGPoint(x: $0.x - offset.x, y: $0.y - offset.y)) }) { return true }
        for a in edges {
            for b in other.edges {
                let cross = a.dx * b.dy - a.dy * b.dx
                guard abs(cross) > 1e-10 else { continue }
                let dx = b.start.x + offset.x - a.start.x, dy = b.start.y + offset.y - a.start.y
                let t = (dx * b.dy - dy * b.dx) / cross
                let u = (dx * a.dy - dy * a.dx) / cross
                if (0...1).contains(t) && (0...1).contains(u) { return true }
            }
        }
        return false
    }
}
