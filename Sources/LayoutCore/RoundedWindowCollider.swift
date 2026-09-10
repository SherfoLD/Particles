import CoreGraphics
import SwiftUI

/// macOS 27 standard windows report 16-point concentric radii. Use Apple's
/// continuous path, sampled once, rather than substituting a quarter circle.
public enum WindowCornerCurve {
    public static let defaultRadius: CGFloat = 16

    // Inward coordinates from the top-right corner, from the top to the side.
    // Twelve samples per cubic keep chord error below 0.02 pt at the default size.
    static let points: [CGPoint] = {
        let path = RoundedRectangle(cornerRadius: 1, style: .continuous)
            .path(in: CGRect(x: 0, y: 0, width: 100, height: 100)).cgPath
        var current = CGPoint.zero
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint, .addLineToPoint:
                current = e.points[0]
            case .addCurveToPoint:
                let a = current, b = e.points[0], c = e.points[1], d = e.points[2]
                if a.x > 98 && a.y < 2 && d.x > 98 && d.y < 2 {
                    if points.isEmpty { points.append(CGPoint(x: 100 - a.x, y: a.y)) }
                    for i in 1...12 {
                        let t = CGFloat(i) / 12, s = 1 - t
                        let x = s*s*s*a.x + 3*s*s*t*b.x + 3*s*t*t*c.x + t*t*t*d.x
                        let y = s*s*s*a.y + 3*s*s*t*b.y + 3*s*t*t*c.y + t*t*t*d.y
                        points.append(CGPoint(x: 100 - x, y: y))
                    }
                }
                current = d
            default: break
            }
        }
        precondition(points.count >= 4)
        return points
    }()

    static let extent = max(points.first!.x, points.last!.y)

    struct Edge {
        let x: CGFloat, y: CGFloat
        let dx: CGFloat, dy: CGFloat
        let inverseLengthSquared: CGFloat
        let nx: CGFloat, ny: CGFloat
    }

    static let edges: [Edge] = (1..<points.count).map { i in
        let a = points[i - 1], b = points[i]
        let dx = b.x - a.x, dy = b.y - a.y
        let squared = dx * dx + dy * dy
        let length = sqrt(squared)
        return Edge(x: a.x, y: a.y, dx: dx, dy: dy, inverseLengthSquared: 1 / squared,
                    nx: -dy / length, ny: dx / length)
    }

    static func clampedRadius(_ radius: CGFloat, in rect: CGRect) -> CGFloat {
        min(max(0, radius.isFinite ? radius : defaultRadius), min(rect.width, rect.height) / (2 * extent))
    }

    public static func path(in rect: CGRect, radius: CGFloat = defaultRadius) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: vertices(in: rect, radius: radius))
        path.closeSubpath()
        return path
    }

    static func vertices(in rect: CGRect, radius: CGFloat) -> [CGPoint] {
        let radius = clampedRadius(radius, in: rect)
        guard radius > 0 else {
            return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        }
        var vertices: [CGPoint] = []
        for corner in 0..<4 {
            let sx: CGFloat = corner < 2 ? 1 : -1
            let sy: CGFloat = corner == 0 || corner == 3 ? 1 : -1
            let samples = corner.isMultiple(of: 2) ? points : points.reversed().map { $0 }
            vertices += samples.map { p in
                CGPoint(x: rect.midX + sx * (rect.width / 2 - p.x * radius),
                        y: rect.midY + sy * (rect.height / 2 - p.y * radius))
            }
        }
        return vertices
    }
}

/// Fast straight-edge contacts with a cached continuous curve at each corner.
/// Distance to the outline supplies true circular ball clearance, including at
/// tessellation vertices; only balls near a corner scan the small curve table.
struct RoundedWindowCollider {
    struct Contact {
        let point: CGPoint
        let nx: CGFloat
        let ny: CGFloat
    }

    let centerX: CGFloat
    let centerY: CGFloat
    let halfWidth: CGFloat
    let halfHeight: CGFloat
    let radius: CGFloat
    let extent: CGFloat

    init(_ rect: CGRect, radius: CGFloat) {
        self.radius = WindowCornerCurve.clampedRadius(radius, in: rect)
        centerX = rect.midX
        centerY = rect.midY
        halfWidth = rect.width / 2
        halfHeight = rect.height / 2
        extent = self.radius * WindowCornerCurve.extent
    }

    // Signed distance and outward normal in inward corner coordinates.
    private func distance(x: CGFloat, y: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        if x >= extent || y >= extent {
            return x < y ? (-x, -1, 0) : (-y, 0, -1)
        }
        if radius == 0 {
            let length = hypot(x, y)
            return (length, x / length, y / length)
        }
        let x = x / radius, y = y / radius
        var bestSquared = CGFloat.infinity
        var bestDX: CGFloat = 0, bestDY: CGFloat = 0
        var bestNX: CGFloat = 0, bestNY: CGFloat = 0
        var outside = false
        for edge in WindowCornerCurve.edges {
            let px = x - edge.x, py = y - edge.y
            if edge.nx * px + edge.ny * py > 0 { outside = true }
            let t = min(1, max(0, (px * edge.dx + py * edge.dy) * edge.inverseLengthSquared))
            let qx = px - t * edge.dx, qy = py - t * edge.dy
            let distanceSquared = qx * qx + qy * qy
            if distanceSquared < bestSquared {
                bestSquared = distanceSquared
                bestDX = qx; bestDY = qy
                bestNX = edge.nx; bestNY = edge.ny
            }
        }
        let length = sqrt(bestSquared)
        if outside && length > 1e-10 { return (length * radius, bestDX / length, bestDY / length) }
        return (-length * radius, bestNX, bestNY)
    }

    func contains(_ point: CGPoint, clearance: CGFloat) -> Bool {
        let x = halfWidth - abs(point.x - centerX)
        let y = halfHeight - abs(point.y - centerY)
        guard x > -clearance, y > -clearance else { return false }
        if x >= extent || y >= extent { return true }
        return distance(x: x, y: y).0 < clearance
    }

    func nearestBoundary(to point: CGPoint, clearance: CGFloat) -> Contact {
        let dx = point.x - centerX, dy = point.y - centerY
        let (distance, ix, iy) = distance(x: halfWidth - abs(dx), y: halfHeight - abs(dy))
        let nx = -ix * (dx < 0 ? -1 : 1), ny = -iy * (dy < 0 ? -1 : 1)
        return Contact(point: CGPoint(x: point.x + (clearance - distance) * nx,
                                      y: point.y + (clearance - distance) * ny), nx: nx, ny: ny)
    }

    /// Axis intersections retain union recovery when another window covers the
    /// nearest corner. Straight sections stay analytic; curved sections use a
    /// bounded search only on this uncommon recovery path.
    func verticalBoundaries(at x: CGFloat, clearance: CGFloat) -> (Contact, Contact)? {
        let inset = halfWidth - abs(x - centerX)
        guard inset > -clearance else { return nil }
        var offset = halfHeight + clearance
        if inset < extent {
            var low = halfHeight - extent, high = offset
            for _ in 0..<22 {
                let middle = (low + high) / 2
                if contains(CGPoint(x: x, y: centerY + middle), clearance: clearance) { low = middle }
                else { high = middle }
            }
            offset = high
        }
        let top = nearestBoundary(to: CGPoint(x: x, y: centerY + offset), clearance: clearance)
        return (top, Contact(point: CGPoint(x: top.point.x, y: 2 * centerY - top.point.y), nx: top.nx, ny: -top.ny))
    }

    func horizontalBoundaries(at y: CGFloat, clearance: CGFloat) -> (Contact, Contact)? {
        let inset = halfHeight - abs(y - centerY)
        guard inset > -clearance else { return nil }
        var offset = halfWidth + clearance
        if inset < extent {
            var low = halfWidth - extent, high = offset
            for _ in 0..<22 {
                let middle = (low + high) / 2
                if contains(CGPoint(x: centerX + middle, y: y), clearance: clearance) { low = middle }
                else { high = middle }
            }
            offset = high
        }
        let right = nearestBoundary(to: CGPoint(x: centerX + offset, y: y), clearance: clearance)
        return (right, Contact(point: CGPoint(x: 2 * centerX - right.point.x, y: right.point.y), nx: -right.nx, ny: right.ny))
    }
}
