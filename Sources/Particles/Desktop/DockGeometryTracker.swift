import AppKit
import Darwin
#if SWIFT_PACKAGE
import LayoutCore
#endif

/// Screen-space Dock geometry. AppKit coordinates have their origin at the
/// bottom left; Window Server coordinates start at the primary display's top left.
struct DockGeometry {
    enum Position {
        case bottom, left, right
    }

    let rect: CGRect
    let position: Position

    /// Calibrated to the visible shelf rim in the desktop reference images.
    /// The measured box extends slightly beyond that rim even after removing
    /// the screen-edge gap. Keep this fit shared with the performance fixture.
    static func collisionShape(in rect: CGRect) -> CollisionShape {
        let inset = min(1, min(rect.width, rect.height) / 4)
        let surface = rect.insetBy(dx: inset, dy: inset)
        return .continuousRoundedRect(surface, radius: min(surface.width, surface.height) * 0.32)
    }

    /// visibleFrame tells us the Dock's thickness, but not its length. Ignore
    /// the top inset (menu bar) and the one-point auto-hide activation strip.
    static func reservedArea(frame: CGRect, visibleFrame: CGRect) -> DockGeometry? {
        let bottom = visibleFrame.minY - frame.minY
        let left = visibleFrame.minX - frame.minX
        let right = frame.maxX - visibleFrame.maxX
        if bottom > 1 {
            return DockGeometry(rect: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: bottom), position: .bottom)
        }
        if left > 1 {
            return DockGeometry(rect: CGRect(x: frame.minX, y: frame.minY, width: left, height: frame.height), position: .left)
        }
        if right > 1 {
            return DockGeometry(rect: CGRect(x: visibleFrame.maxX, y: frame.minY, width: right, height: frame.height), position: .right)
        }
        return nil
    }

    static func appKitRect(from windowRect: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(x: windowRect.minX, y: primaryScreenTop - windowRect.maxY, width: windowRect.width, height: windowRect.height)
    }

    /// Some macOS versions expose a tight Dock window; others report a
    /// full-screen surface. Never use that as an obstacle.
    static func windowArea(_ rect: CGRect, on frame: CGRect) -> DockGeometry? {
        let clipped = rect.intersection(frame)
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              !clipped.isEmpty, !clipped.isNull else { return nil }
        if clipped.width > clipped.height, clipped.height > 1, clipped.height < frame.height / 2, clipped.width < frame.width * 0.98,
           abs(clipped.minY - frame.minY) <= 12 {
            return DockGeometry(rect: clipped, position: .bottom)
        }
        if clipped.height > clipped.width, clipped.width > 1, clipped.width < frame.width / 2, clipped.height < frame.height * 0.98 {
            if abs(clipped.minX - frame.minX) <= 12 {
                return DockGeometry(rect: clipped, position: .left)
            }
            if abs(clipped.maxX - frame.maxX) <= 12 {
                return DockGeometry(rect: clipped, position: .right)
            }
        }
        return nil
    }
}

/// Query at most ten times per second, independent of the 240 Hz physics step.
/// CoreDock supplies the actual length even when Window Server exposes a full-
/// screen backing surface. This is optional private SPI, resolved dynamically;
/// if unavailable we only accept tight public window bounds. No capture or AX.
@MainActor
final class DockGeometryTracker {
    private var nextRefresh: TimeInterval = 0
    private var windowRects: [CGRect] = []
    private var dockRect: CGRect?

    // Signature documented by the CoreDock header's author:
    // https://gist.github.com/w0lfschild/90db263867f469738c01e9e2d937f874
    private typealias GetDockRect = @convention(c) (UnsafeMutablePointer<CGRect>) -> Void
    private static let getDockRect: GetDockRect? = {
        guard let library = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY | RTLD_LOCAL),
              let symbol = dlsym(library, "CoreDockGetRect") else { return nil }
        return unsafeBitCast(symbol, to: GetDockRect.self)
    }()

    private static func readDockRect() -> CGRect? {
        guard let getDockRect, let primary = NSScreen.screens.first else { return nil }
        var rect = CGRect.zero
        getDockRect(&rect)
        guard rect.width > 1, rect.height > 1, rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        return DockGeometry.appKitRect(from: rect, primaryScreenTop: primary.frame.maxY)
    }

    func invalidate() {
        nextRefresh = 0
    }

    func geometry(on screen: NSScreen, at time: TimeInterval) -> DockGeometry? {
        if time >= nextRefresh {
            nextRefresh = time + 0.1
            dockRect = Self.readDockRect()
            windowRects = Self.readWindowRects()
        }
        if let dockRect, let geometry = DockGeometry.windowArea(dockRect, on: screen.frame) {
            // CoreDock includes the five-point gap between the shelf and screen.
            var surface = geometry.rect
            switch geometry.position {
            case .bottom: surface.origin.y += 5; surface.size.height -= 5
            case .left: surface.origin.x += 5; surface.size.width -= 5
            case .right: surface.size.width -= 5
            }
            if !surface.isEmpty { return DockGeometry(rect: surface, position: geometry.position) }
        }
        let reserved = DockGeometry.reservedArea(frame: screen.frame, visibleFrame: screen.visibleFrame)
        let measured = windowRects.compactMap { DockGeometry.windowArea($0, on: screen.frame) }
            .filter { reserved == nil || $0.position == reserved?.position }
            .max { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
        // visibleFrame has no longitudinal bounds: never turn its reserved strip
        // into an invisible wall across the whole screen.
        return measured
    }

    private static func readWindowRects() -> [CGRect] {
        guard let primary = NSScreen.screens.first,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return windows.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? NSNumber, pid.int32Value == dock.processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? NSNumber, layer.int32Value == CGWindowLevelForKey(.dockWindow),
                  let alpha = window[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return DockGeometry.appKitRect(from: rect, primaryScreenTop: primary.frame.maxY)
        }
    }
}
