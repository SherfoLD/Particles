import AppKit
import QuickLookThumbnailing
#if SWIFT_PACKAGE
import LayoutCore
#endif

/// Artwork work happens between scans, never in the render/physics loop. Finder
/// owns the positions; Quick Look supplies a best-effort version of its artwork.
actor DesktopIconGeometry {
    private struct Key: Equatable {
        let size: CGFloat
        let previews: Bool
        let modified: Date?
        let attributesModified: Date?
        let bytes: Int?
    }

    private struct Entry {
        let key: Key
        var outline: [CGPoint]?
        var source: String
        var attemptedPreview = false
    }

    private struct Pending {
        let token: UUID
        let request: QLThumbnailGenerator.Request
        let timeout: Task<Void, Never>
    }

    private var cache: [String: Entry] = [:]
    private var pending: [String: Pending] = [:]

    func resolve(_ items: [DesktopItem], previews: Bool) -> [DesktopItem] {
        let liveIDs = Set(items.map(\.id))
        for id in Array(cache.keys) where !liveIDs.contains(id) {
            cancel(id)
            cache.removeValue(forKey: id)
        }
        return items.map { item in
            guard item.kind != .widget, let url = URL(string: item.id), url.isFileURL else { return item }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                .attributeModificationDateKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            let side = item.size?.width ?? 48
            let key = Key(size: side, previews: previews, modified: values?.contentModificationDate,
                          attributesModified: values?.attributeModificationDate, bytes: values?.fileSize)
            if cache[item.id]?.key != key {
                cancel(item.id)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                var rect = CGRect(x: 0, y: 0, width: side, height: side)
                let outline = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                    .flatMap { IconAlphaOutline.trace($0, iconSide: side) }
                cache[item.id] = Entry(key: key, outline: outline, source: "system icon alpha outline")
            }
            // Don't request previews that could download an iCloud placeholder.
            let isLocal = values?.isUbiquitousItem != true ||
                values?.ubiquitousItemDownloadingStatus == .current ||
                values?.ubiquitousItemDownloadingStatus == .downloaded
            if previews, item.kind == .file, isLocal, pending.count < 4,
               cache[item.id]?.attemptedPreview == false {
                requestPreview(url, id: item.id, side: side)
            }
            let entry = cache[item.id]!
            return DesktopItem(id: item.id, name: item.name, kind: item.kind,
                               position: item.position, size: item.size,
                               source: item.source + " · " + entry.source, iconOutline: entry.outline)
        }
    }

    private func cancel(_ id: String) {
        guard let work = pending.removeValue(forKey: id) else { return }
        work.timeout.cancel()
        QLThumbnailGenerator.shared.cancel(work.request)
    }

    private func requestPreview(_ url: URL, id: String, side: CGFloat) {
        cache[id]?.attemptedPreview = true
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: 2, representationTypes: .thumbnail)
        request.iconMode = true
        let token = UUID()
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await self?.finish(id, token: token, outline: nil)
        }
        pending[id] = Pending(token: token, request: request, timeout: timeout)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let outline = representation.flatMap { IconAlphaOutline.trace($0.cgImage, iconSide: side) }
            Task { await self?.finish(id, token: token, outline: outline) }
        }
    }

    private func finish(_ id: String, token: UUID, outline: [CGPoint]?) {
        guard pending[id]?.token == token else { return }
        cancel(id)
        if let outline {
            cache[id]?.outline = outline
            cache[id]?.source = "Quick Look icon-mode alpha outline (approximate Finder artwork)"
        }
    }
}

/// Trace the largest opaque component's exterior, retaining concavities. Tiny
/// detached badges and interior holes are deliberately excluded. The existing
/// solver consumes one simple polygon per item, capped at 96 edges.
enum IconAlphaOutline {
    static func trace(_ image: CGImage, iconSide: CGFloat) -> [CGPoint]? {
        let side = max(16, min(256, Int(ceil(iconSide * 2))))
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            let scale = min(CGFloat(side) / CGFloat(image.width), CGFloat(side) / CGFloat(image.height))
            let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2,
                                          width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        func solid(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < side && y < side && pixels[(y * side + x) * 4 + 3] >= 128
        }
        let stride = side + 1
        var edges: [Int: [Int]] = [:]
        func edge(_ x: Int, _ y: Int, _ endX: Int, _ endY: Int) {
            edges[y * stride + x, default: []].append(endY * stride + endX)
        }
        for y in 0..<side {
            for x in 0..<side where solid(x, y) {
                if !solid(x, y - 1) { edge(x, y, x + 1, y) }
                if !solid(x + 1, y) { edge(x + 1, y, x + 1, y + 1) }
                if !solid(x, y + 1) { edge(x + 1, y + 1, x, y + 1) }
                if !solid(x - 1, y) { edge(x, y + 1, x, y) }
            }
        }
        func point(_ value: Int) -> CGPoint { CGPoint(x: value % stride, y: value / stride) }
        func direction(_ a: Int, _ b: Int) -> Int {
            let delta = b - a
            return delta == 1 ? 0 : delta == stride ? 1 : delta == -1 ? 2 : 3
        }
        var largest: [CGPoint] = [], largestArea: CGFloat = 0
        while let start = edges.keys.first {
            var loop: [CGPoint] = [], current = start, incoming: Int?
            repeat {
                loop.append(point(current))
                guard let candidates = edges[current], !candidates.isEmpty else { break }
                // At a diagonal pixel contact, turn left to stay on this component.
                let next = candidates.min { a, b in
                    guard let incoming else { return a < b }
                    let preference = [1, 0, 3, 2]
                    return preference.firstIndex(of: (direction(current, a) - incoming + 4) % 4)! <
                        preference.firstIndex(of: (direction(current, b) - incoming + 4) % 4)!
                }!
                edges[current]?.removeAll { $0 == next }
                if edges[current]?.isEmpty == true { edges.removeValue(forKey: current) }
                incoming = direction(current, next)
                current = next
            } while current != start
            guard current == start, loop.count >= 3 else { continue }
            let area = loop.indices.reduce(CGFloat.zero) { sum, i in
                let a = loop[i], b = loop[(i + 1) % loop.count]
                return sum + a.x * b.y - b.x * a.y
            }
            if area > largestArea { largestArea = area; largest = loop }
        }
        guard largest.count >= 3 else { return [] }
        // Remove pixel-edge collinearity before simplifying curved boundaries.
        let corners = largest.indices.compactMap { i -> CGPoint? in
            let a = largest[(i + largest.count - 1) % largest.count]
            let b = largest[i], c = largest[(i + 1) % largest.count]
            return (b.x - a.x) * (c.y - b.y) == (b.y - a.y) * (c.x - b.x) ? nil : b
        }
        let split = corners.count / 2
        var tolerance: CGFloat = 0.75
        var outline: [CGPoint]
        repeat {
            let first = simplify(Array(corners[...split]), tolerance: tolerance)
            let second = simplify(Array(corners[split...]) + [corners[0]], tolerance: tolerance)
            outline = Array(first.dropLast()) + Array(second.dropLast())
            tolerance *= 1.5
        } while outline.count > 96
        // Simplification of a narrow concavity can cross another edge. Use the
        // component's convex hull in that exceptional case, never a broken polygon.
        if outline.count < 3 || selfIntersects(outline) { outline = convexHull(corners) }
        if outline.count > 96 {
            let xs = corners.map(\.x), ys = corners.map(\.y)
            outline = [CGPoint(x: xs.min()!, y: ys.min()!), CGPoint(x: xs.max()!, y: ys.min()!),
                       CGPoint(x: xs.max()!, y: ys.max()!), CGPoint(x: xs.min()!, y: ys.max()!)]
        }
        // Bitmap memory rows run top-to-bottom even though Quartz drawing uses
        // bottom-left coordinates. Convert once before handing points to physics.
        return outline.map { CGPoint(x: $0.x / CGFloat(side), y: 1 - $0.y / CGFloat(side)) }
    }

    private static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let a = points.first!, b = points.last!, dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        var maximum: CGFloat = 0, split = 0
        for i in 1..<(points.count - 1) {
            let p = points[i]
            let t = length == 0 ? 0 : min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
            let distance = pow(p.x - a.x - t * dx, 2) + pow(p.y - a.y - t * dy, 2)
            if distance > maximum { maximum = distance; split = i }
        }
        guard maximum > tolerance * tolerance else { return [a, b] }
        return Array(simplify(Array(points[...split]), tolerance: tolerance).dropLast()) +
            simplify(Array(points[split...]), tolerance: tolerance)
    }

    private static func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func selfIntersects(_ points: [CGPoint]) -> Bool {
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            for j in points.indices where j > i + 1 && !(i == 0 && j == points.count - 1) {
                let c = points[j], d = points[(j + 1) % points.count]
                if max(a.x, b.x) < min(c.x, d.x) || max(c.x, d.x) < min(a.x, b.x) ||
                    max(a.y, b.y) < min(c.y, d.y) || max(c.y, d.y) < min(a.y, b.y) { continue }
                if cross(a, b, c) * cross(a, b, d) <= 0 && cross(c, d, a) * cross(c, d, b) <= 0 { return true }
            }
        }
        return false
    }

    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func half(_ points: [CGPoint]) -> [CGPoint] {
            var result: [CGPoint] = []
            for p in points {
                while result.count > 1 && cross(result[result.count - 2], result.last!, p) <= 0 { result.removeLast() }
                result.append(p)
            }
            return result
        }
        return Array(half(sorted).dropLast()) + Array(half(sorted.reversed()).dropLast())
    }
}
