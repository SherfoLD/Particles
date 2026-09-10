import AppKit

/// Measures contour tracing against synthetic icon artwork.
enum IconGeometryBenchmark {
    private static func writeSnapshot(_ images: [CGImage], to url: URL) {
        guard let context = CGContext(data: nil, width: 1024, height: 256, bitsPerComponent: 8,
            bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 256))
        for (i, image) in images.enumerated() {
            let rect = CGRect(x: i * 256 + 16, y: 16, width: 224, height: 224)
            context.draw(image, in: rect)
            guard let outline = IconAlphaOutline.trace(image, iconSide: 128), outline.count >= 3 else { continue }
            context.addLines(between: outline.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) })
            context.closePath()
            context.setStrokeColor(CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 1))
            context.setLineWidth(2)
            context.strokePath()
        }
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        do { try png.write(to: url) }
        catch { NSLog("Icon benchmark snapshot: %@", error.localizedDescription) }
    }

    static func run() {
        let images = (0..<4).map { SyntheticIconFixtures.artwork($0) }
        var samples: [Double] = [], edges: [Int] = []
        for i in 0..<400 {
            autoreleasepool {
                let start = ProcessInfo.processInfo.systemUptime
                let outline = IconAlphaOutline.trace(images[i % 4], iconSide: i < 200 ? 64 : 128)
                samples.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
                edges.append(outline?.count ?? 0)
            }
        }
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            writeSnapshot(images, to: URL(fileURLWithPath: args[index + 1]))
        }
        PerformanceReport.printJSON(["mode": "synthetic-icon-geometry", "iterations": samples.count,
            "trace128PixelsMs": PerformanceReport.summary(Array(samples.prefix(200))),
            "trace256PixelsMs": PerformanceReport.summary(Array(samples.suffix(200))),
            "maximumEdges": edges.max() ?? 0])
    }
}
