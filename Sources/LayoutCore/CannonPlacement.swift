import Foundation
import CoreGraphics

/// Sprite layout in points, shared by drawing, picking, emission and collisions.
public enum CannonGeometry {
    public static let viewSize = CGSize(width: 168, height: 168)
    public static let pivot = CGPoint(x: 84, y: 84)
    public static let wheelRadius: CGFloat = 21
    public static let wheelRect = CGRect(x: pivot.x - wheelRadius, y: pivot.y - wheelRadius,
                                        width: wheelRadius * 2, height: wheelRadius * 2)
    public static let wheelCrop = CGRect(x: 95, y: 117, width: 1063, height: 1063)
    public static let barrelCrop = CGRect(x: 273, y: 51, width: 708, height: 1157)
    private static let barrelScale: CGFloat = 82 / barrelCrop.height
    // The upright barrel starts one third of the wheel's diameter above its bottom.
    public static let barrelRect = CGRect(x: -barrelCrop.width * barrelScale / 2, y: -wheelRadius / 3,
                                         width: barrelCrop.width * barrelScale, height: 82)
    public static let muzzleDistance = barrelRect.maxY
    public static let muzzleHalfWidth: CGFloat = 15

    public static func point(along: CGFloat, across: CGFloat = 0, angle: CGFloat) -> CGPoint {
        CGPoint(x: pivot.x + along * cos(angle) - across * sin(angle),
                y: pivot.y + along * sin(angle) + across * cos(angle))
    }

    private static let wheel = CollisionShape.roundedRect(wheelRect, radius: wheelRadius)
    // Outline of the upright artwork, in source-image pixels (top-left origin).
    // The wheel is a solid collider, including its gaps between the spokes.
    private static let barrelOutline: [CGPoint] = [
        CGPoint(x: 414, y: 51), CGPoint(x: 841, y: 51),
        CGPoint(x: 868, y: 64), CGPoint(x: 879, y: 90),
        CGPoint(x: 868, y: 117), CGPoint(x: 819, y: 128),
        CGPoint(x: 973, y: 850), CGPoint(x: 978, y: 932),
        CGPoint(x: 958, y: 1022), CGPoint(x: 907, y: 1096),
        CGPoint(x: 833, y: 1153), CGPoint(x: 735, y: 1192),
        CGPoint(x: 626, y: 1203), CGPoint(x: 516, y: 1190),
        CGPoint(x: 419, y: 1151), CGPoint(x: 344, y: 1094),
        CGPoint(x: 295, y: 1020), CGPoint(x: 275, y: 930),
        CGPoint(x: 281, y: 850), CGPoint(x: 434, y: 128),
        CGPoint(x: 387, y: 117), CGPoint(x: 375, y: 90),
        CGPoint(x: 387, y: 64)
    ]

    public static func parts(angle: CGFloat) -> [CollisionShape] {
        let barrel = CollisionShape(vertices: barrelOutline.map { pixel in
            let along = (barrelCrop.maxY - pixel.y) * barrelScale + barrelRect.minY
            let across = -(pixel.x - barrelCrop.midX) * barrelScale
            return point(along: along, across: across, angle: angle)
        })
        return [barrel, wheel]
    }
}

/// Shared by the desktop cannon and offscreen performance fixtures. Placement
/// never waits for a worker or exhaustively searches a display in one frame.
public final class CannonPlacement {
    public private(set) var origin: CGPoint
    public private(set) var angle: CGFloat = .pi * 0.31
    public private(set) var isPlaced = false
    public private(set) var localShapes: [CollisionShape]
    public private(set) var obstacles: [CollisionShape] = []
    public var isSearching: Bool { searchIndex != nil }
    private let bounds: CGRect
    private let worldBounds: CGRect
    private var localBounds: CGRect
    private var worldShapes: [CollisionShape]?
    private var sourceShapes: [CollisionShape]?
    private var sourceWindows: [CGRect]?
    private var sourceRadius: CGFloat?
    private var searchIndex: Int?
    private var searchNeedsRestart = false
    private let searchCount: Int
    private static let directions = (0..<24).map { step in
        let theta = CGFloat(step) * .pi / 12
        return CGPoint(x: cos(theta), y: sin(theta))
    }

    public init(bounds: CGRect) {
        worldBounds = bounds
        self.bounds = bounds.insetBy(dx: 2, dy: 2)
        origin = CGPoint(x: bounds.minX + bounds.width * 0.3, y: bounds.minY + max(100, bounds.height * 0.25))
        localShapes = CannonGeometry.parts(angle: angle)
        localBounds = localShapes.reduce(CGRect.null) { $0.union($1.bounds) }
        searchCount = max(0, Int(floor((max(bounds.width, bounds.height) - 12) / 24)) + 1) * 24
    }

    public var collisionShapes: [CollisionShape] {
        guard isPlaced else { return [] }
        if worldShapes == nil { worldShapes = localShapes.map { $0.translated(by: origin) } }
        return worldShapes!
    }

    /// Call every frame, including unchanged snapshots, to continue pending work.
    public func updateObstacles(_ shapes: [CollisionShape], windows: [CGRect], cornerRadius: CGFloat) {
        if sourceShapes != shapes || sourceWindows != windows || sourceRadius != cornerRadius {
            sourceShapes = shapes
            sourceWindows = windows
            sourceRadius = cornerRadius
            obstacles = shapes + windows.map {
                CollisionShape.continuousRoundedRect($0, radius: $0.contains(worldBounds) ? 0 : cornerRadius)
            }
            if fits(origin) {
                isPlaced = true
                searchIndex = nil
                return
            }
            isPlaced = false
            // Preserve progress during a continuous drag. Every candidate is
            // checked against the latest geometry, so stale results cannot place us.
            searchNeedsRestart = searchIndex != nil
            if searchIndex == nil { searchIndex = 0 }
            if windows.contains(where: { $0.contains(worldBounds) }) { searchIndex = nil }
        }
        guard let first = searchIndex else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.001
        // The count also bounds work on machines with coarse clock resolution.
        for index in first..<min(first + 512, searchCount) {
            let direction = Self.directions[index % 24]
            let distance = CGFloat(12 + (index / 24) * 24)
            let candidate = CGPoint(x: origin.x + direction.x * distance, y: origin.y + direction.y * distance)
            if move(to: candidate) { searchIndex = nil; return }
            if index + 1 < searchCount { searchIndex = index + 1 }
            else {
                // Earlier candidates may have become free since we visited them.
                searchIndex = searchNeedsRestart ? 0 : nil
                searchNeedsRestart = false
                return
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { return }
        }
    }

    private func fits(_ position: CGPoint, shapes: [CollisionShape]? = nil, shapeBounds: CGRect? = nil) -> Bool {
        guard bounds.contains((shapeBounds ?? localBounds).offsetBy(dx: position.x, dy: position.y)) else { return false }
        return (shapes ?? localShapes).allSatisfy { part in
            !obstacles.contains { $0.intersects(part, offsetBy: position) }
        }
    }

    @discardableResult public func move(to position: CGPoint) -> Bool {
        guard fits(position) else { return false }
        if origin != position { origin = position; worldShapes = nil }
        isPlaced = true
        searchIndex = nil
        return true
    }

    @discardableResult public func aim(to proposed: CGFloat) -> Bool {
        guard proposed != angle else { return true }
        let shapes = CannonGeometry.parts(angle: proposed)
        let shapeBounds = shapes.reduce(CGRect.null) { $0.union($1.bounds) }
        guard fits(origin, shapes: shapes, shapeBounds: shapeBounds) else { return false }
        angle = proposed
        localShapes = shapes
        localBounds = shapeBounds
        worldShapes = nil
        return true
    }

}
