import CoreGraphics

/// A small circular brush, with a swept capsule for motion between physics frames.
/// Kept outside geometryRevision: moving it never rebuilds polygons/window exits.
struct CursorCollider {
    static let radius = ParticleEngine.cursorRadius
    let start: CGPoint
    let end: CGPoint
    let velocity: CGVector
    let inverseLengthSquared: CGFloat
    let sweepBounds: CGRect

    init(start: CGPoint, end: CGPoint, duration: CGFloat, maximumSpeed: CGFloat) {
        self.start = start
        self.end = end
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        inverseLengthSquared = lengthSquared > 0.000001 ? 1 / lengthSquared : 0
        let scale = lengthSquared > 0 ? min(1 / max(duration, 0.001), maximumSpeed / sqrt(lengthSquared)) : 0
        velocity = CGVector(dx: dx * scale, dy: dy * scale)
        sweepBounds = CGRect(x: min(start.x, end.x) - Self.radius, y: min(start.y, end.y) - Self.radius,
                             width: abs(dx) + 2 * Self.radius, height: abs(dy) + 2 * Self.radius)
    }

    // Mirror cursorContact in Metal. Only hits pay for projection and square root.
    func resolve(position: inout CGPoint, velocity: inout CGVector, radius: CGFloat, swept: Bool) {
        let reach = Self.radius + radius
        var center = end
        if swept {
            guard sweepBounds.insetBy(dx: -radius, dy: -radius).contains(position) else { return }
            let dx = end.x - start.x, dy = end.y - start.y
            let t = min(1, max(0, ((position.x - start.x) * dx + (position.y - start.y) * dy) * inverseLengthSquared))
            center = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        } else if abs(position.x - end.x) >= reach || abs(position.y - end.y) >= reach { return }
        let dx = position.x - center.x, dy = position.y - center.y
        let squared = dx * dx + dy * dy
        guard squared < reach * reach else { return }
        let distance = sqrt(squared)
        // A point exactly on the stroke moves sideways, never along its full length.
        let length = hypot(end.x - start.x, end.y - start.y)
        let nx = distance > 0.0001 ? dx / distance : (length > 0.0001 ? -(end.y - start.y) / length : 0)
        let ny = distance > 0.0001 ? dy / distance : (length > 0.0001 ? (end.x - start.x) / length : 1)
        let correction = swept ? reach - distance : min(reach - distance, radius * 0.5)
        position.x += nx * correction
        position.y += ny * correction
        // A bounded outward brush impulse also makes fast sideways strokes useful.
        let brushSpeed = swept ? hypot(self.velocity.dx, self.velocity.dy) * 0.25 : 0
        let target = max(0, self.velocity.dx * nx + self.velocity.dy * ny) + brushSpeed
        let impulse = max(0, target - velocity.dx * nx - velocity.dy * ny)
        velocity.dx += nx * impulse
        velocity.dy += ny * impulse
    }
}
