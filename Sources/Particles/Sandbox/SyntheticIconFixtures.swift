import AppKit
#if SWIFT_PACKAGE
import LayoutCore
#endif

/// Synthetic icon artwork and contours; no desktop access.
enum SyntheticIconFixtures {
    static func artwork(_ index: Int, side: Int = 128) -> CGImage {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(side), y: CGFloat(side))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        switch index % 4 {
        case 0: context.fill(CGRect(x: 0.04, y: 0.28, width: 0.92, height: 0.44))
        case 1: context.fill(CGRect(x: 0.3, y: 0.04, width: 0.4, height: 0.92))
        case 2:
            context.addLines(between: [CGPoint(x: 0.15, y: 0.05), CGPoint(x: 0.85, y: 0.05),
                CGPoint(x: 0.85, y: 0.72), CGPoint(x: 0.62, y: 0.95), CGPoint(x: 0.15, y: 0.95)])
            context.closePath(); context.fillPath()
        default:
            context.addPath(CGPath(roundedRect: CGRect(x: 0.04, y: 0.12, width: 0.92, height: 0.68),
                                   cornerWidth: 0.06, cornerHeight: 0.06, transform: nil))
            context.fillPath()
            context.fill(CGRect(x: 0.09, y: 0.75, width: 0.3, height: 0.15))
        }
        return context.makeImage()!
    }

    private static let outlines = (0..<4).map { IconAlphaOutline.trace(artwork($0), iconSide: 64) ?? [] }

    static func fixtures(in bounds: CGRect) -> [CollisionShape] {
        (0..<60).compactMap { i in
            let item = DesktopItem(id: "synthetic-\(i)", name: "Synthetic icon", kind: .file,
                position: CGPoint(x: bounds.width * (0.08 + CGFloat(i % 10) * 0.09),
                                  y: bounds.height * (0.15 + CGFloat(i / 10) * 0.12)),
                size: CGSize(width: 64, height: 64), source: "performance fixture", iconOutline: outlines[i % 4])
            return item.collisionShape(on: bounds)
        }
    }
}
