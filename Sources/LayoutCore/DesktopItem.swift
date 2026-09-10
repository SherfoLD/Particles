import Foundation
import CoreGraphics

public struct DesktopItem: Identifiable, Sendable {
    public enum Kind: String, Sendable { case folder, file, widget }
    public let id: String
    public let name: String
    public let kind: Kind
    /// Global desktop points, origin at the primary display's upper-left.
    /// Finder supplies the icon center; Window Server supplies a top-left corner.
    public let position: CGPoint
    /// Configured icon box (excluding label) for files and folders; window bounds for widgets.
    public let size: CGSize?
    public let source: String
    /// Normalized artwork outline in the icon box, with a bottom-left origin.
    /// Nil means artwork is unavailable; an empty outline means transparent artwork.
    public let iconOutline: [CGPoint]?

    public init(id: String, name: String, kind: Kind, position: CGPoint, size: CGSize?, source: String, iconOutline: [CGPoint]? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.position = position
        self.size = size
        self.source = source
        self.iconOutline = iconOutline
    }

    public var mapFrame: CGRect {
        if kind != .widget {
            // Keep the icon-center anchor even when Finder supplies a size.
            // If unavailable, the 48-point square is only a map marker.
            let iconSize = size ?? CGSize(width: 48, height: 48)
            return CGRect(x: position.x - iconSize.width / 2, y: position.y - iconSize.height / 2,
                          width: iconSize.width, height: iconSize.height)
        }
        if let size { return CGRect(origin: position, size: size) }
        return CGRect(x: position.x - 24, y: position.y - 24, width: 48, height: 48)
    }

    /// Artwork bounds, in display-local bottom-left points. Keep the original
    /// shape across display edges; clipping its box first would shift the artwork.
    public func collisionShape(on display: CGRect) -> CollisionShape? {
        guard mapFrame.intersects(display) else { return nil }
        let frame = CGRect(x: mapFrame.minX - display.minX, y: display.maxY - mapFrame.maxY,
                           width: mapFrame.width, height: mapFrame.height)
        if kind != .widget, let iconOutline {
            guard iconOutline.count >= 3 else { return nil }
            return CollisionShape(vertices: iconOutline.map {
                CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height)
            })
        }
        switch kind {
        case .widget:
            // Notification Center includes an eight-point transparent gutter.
            let surface = frame.insetBy(dx: 8, dy: 8)
            guard !surface.isEmpty else { return nil }
            return .roundedRect(surface, radius: 26)
        case .file:
            // A failed artwork read must not invent a square wall around a file.
            return nil
        case .folder:
            return Self.folderCollisionShape(in: frame)
        }
    }

    /// Shared by live desktop geometry and synthetic obstacle types.
    public static func folderCollisionShape(in frame: CGRect) -> CollisionShape {
        // Normalized Finder folder silhouette, excluding the icon's padding
        // and shadow. The raised tab makes the upper edge concave.
        let outline: [(CGFloat, CGFloat)] = [
            (0.045, 0.17), (0.06, 0.135), (0.10, 0.125), (0.90, 0.125),
            (0.94, 0.14), (0.955, 0.18), (0.955, 0.745), (0.94, 0.785),
            (0.91, 0.80), (0.40, 0.80), (0.33, 0.87), (0.10, 0.87),
            (0.06, 0.85), (0.045, 0.81)
        ]
        return CollisionShape(vertices: outline.map {
            CGPoint(x: frame.minX + $0.0 * frame.width, y: frame.minY + $0.1 * frame.height)
        })
    }

    /// A solid obstacle in a display-local, bottom-left coordinate system.
    /// Finder's icon-center and Window Server's top-left anchors meet here.
    public func collisionFrame(on display: CGRect) -> CGRect? {
        let clipped = mapFrame.intersection(display)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        return CGRect(x: clipped.minX - display.minX, y: display.maxY - clipped.maxY,
                      width: clipped.width, height: clipped.height)
    }
}

public enum DesktopGeometry {
    public static func bounds(of displays: [CGRect]) -> CGRect {
        displays.reduce(CGRect.null) { $0.union($1) }
    }

    public static func transform(_ rect: CGRect, desktop: CGRect, canvas: CGSize, padding: CGFloat = 24) -> CGRect {
        guard desktop.width > 0, desktop.height > 0 else { return .zero }
        let scale = max(0, min((canvas.width - padding * 2) / desktop.width,
                               (canvas.height - padding * 2) / desktop.height))
        let offset = CGPoint(x: (canvas.width - desktop.width * scale) / 2,
                             y: (canvas.height - desktop.height * scale) / 2)
        return CGRect(x: offset.x + (rect.minX - desktop.minX) * scale,
                      y: offset.y + (rect.minY - desktop.minY) * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }

    /// Notification Center's below-normal windows are desktop-widget candidates.
    /// This is a best-effort heuristic, not a WidgetKit enumeration API.
    public static func isDesktopWidget(bundleID: String?, layer: Int, frame: CGRect,
                                       alpha: Double, displays: [CGRect]) -> Bool {
        guard bundleID == "com.apple.notificationcenterui", layer < 0, alpha > 0,
              frame.width >= 40, frame.height >= 40,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite else { return false }
        let overlapping = displays.filter { $0.intersects(frame) }
        guard !overlapping.isEmpty else { return false }
        // Reject desktop-sized backing surfaces and Notification Center panels.
        return !overlapping.contains { frame.width >= $0.width * 0.9 && frame.height >= $0.height * 0.9 }
    }
}
