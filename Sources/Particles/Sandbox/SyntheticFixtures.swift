import Foundation
import CoreGraphics
#if SWIFT_PACKAGE
import LayoutCore
#endif

/// Fixed performance fixtures shared by the sandbox and benchmark runners.
enum SyntheticFixtures {
    static var cursorFixture: Bool { CommandLine.arguments.contains("--cursor-fixture") }
    static var squeezeFixture: Bool { CommandLine.arguments.contains("--squeeze-fixture") }
    static var settledFixture: Bool { CommandLine.arguments.contains("--settled-pile-fixture") }
    static var usesPile: Bool {
        squeezeFixture || settledFixture || CommandLine.arguments.contains("--pile-drag-fixture") ||
            CommandLine.arguments.contains("--compressed-pile-fixture")
    }
    static let flags = ["--cannon-fixture", "--window-fixtures", "--file-icon-fixtures", "--pile-drag-fixture",
                        "--compressed-pile-fixture", "--settled-pile-fixture", "--squeeze-fixture", "--cursor-fixture"]
    static var isSelected: Bool { flags.contains(where: CommandLine.arguments.contains) }

    static var reportName: String {
        if squeezeFixture { return "squeeze" }
        if settledFixture { return "settled-pile" }
        if CommandLine.arguments.contains("--compressed-pile-fixture") { return "compressed-pile" }
        if usesPile { return "pile-drag" }
        if CommandLine.arguments.contains("--file-icon-fixtures") { return "file-icons" }
        return "rain"
    }

    /// Performance workload: resting contact, slow stirring, fast strokes, then
    /// display exit/re-entry. Uses the same input and solver path as the desktop.
    static func updateCursor(in engine: ParticleEngine, time: Double) {
        guard cursorFixture else { return }
        let phase = time.truncatingRemainder(dividingBy: 10)
        guard phase < 6 || phase >= 7 else { engine.cursorPosition = nil; return }
        let frequency = phase < 2 ? 0 : (phase < 4 ? 0.5 : 6)
        let x = engine.bounds.midX + sin(max(0, phase - 2) * .pi * 2 * frequency) * engine.bounds.width * 0.4
        engine.cursorPosition = CGPoint(x: x, y: engine.bounds.minY + 45 + sin(max(0, phase - 2) * 2) * 25)
    }

    static func fixtures(in bounds: CGRect, time: Double = 0) -> [CollisionShape] {
        if CommandLine.arguments.contains("--file-icon-fixtures") { return SyntheticIconFixtures.fixtures(in: bounds) }
        return [DockGeometry.collisionShape(in: CGRect(x: bounds.width * 0.25, y: 5, width: bounds.width * 0.5, height: 65)),
         CollisionShape.roundedRect(CGRect(x: bounds.width * 0.3 + sin(time) * 60, y: bounds.height * 0.45, width: 180, height: 100), radius: 20),
         CollisionShape(vertices: [CGPoint(x: 850, y: 400), CGPoint(x: 910, y: 400), CGPoint(x: 910, y: 445),
                                   CGPoint(x: 878, y: 445), CGPoint(x: 872, y: 452), CGPoint(x: 850, y: 452)])]
    }

    static func windowFixtures(in bounds: CGRect, time: Double) -> [CGRect] {
        if squeezeFixture {
            // Settle, close the gap against the floor, hold it shut, then release.
            // The roof extends past both side walls: there is no sideways exit.
            let progress = min(1, max(0, (time - 2) / 2))
            if time >= 6 { return [] }
            return [CGRect(x: bounds.minX - 30, y: bounds.minY + 360 * (1 - progress) + 1,
                           width: bounds.width + 60, height: bounds.height)]
        }
        if settledFixture { return [] }
        if usesPile {
            return [pileWindow(in: bounds, time: time)]
        }
        return (0..<12).map { index in
            CGRect(x: bounds.width * (0.08 + Double(index % 4) * 0.18) + sin(time + Double(index)) * 40,
                   y: bounds.height * (0.2 + Double(index / 4) * 0.15),
                   width: bounds.width * 0.24, height: bounds.height * 0.22)
        }
    }

    static func pileWindow(in bounds: CGRect, time: Double = 0) -> CGRect {
        let duration = Double(LaunchArguments.value("--duration", default: LaunchArguments.value("--frames", default: 8640) / 120))
        let moving = !CommandLine.arguments.contains("--compressed-pile-fixture") && time >= 2 && time < duration - 2
        let phase = moving ? time - 2 : 0
        let frequency = Double(LaunchArguments.value("--drag-hz", default: 1))
        return CGRect(x: bounds.width * 0.375 + sin(phase * .pi * 0.5) * 30,
                      y: bounds.height * 0.3 + sin(phase * .pi * 2 * frequency) * 160,
                      width: bounds.width * 0.25, height: bounds.height * 0.3)
    }

    /// Start with a deep pile so dragging performance need not wait for minutes
    /// of rain to collect on a window. The fixture rests, drags, then rests again.
    static func pile(count: Int, bounds: CGRect, radius: CGFloat = 1.5) -> ParticleEngine {
        let diameter = radius * 2
        let rowHeight = radius * (2.6 / 1.5)
        if squeezeFixture || settledFixture {
            let columns = max(1, Int((bounds.width - diameter * 2) / diameter))
            return ParticleEngine(particles: (0..<count).map { i in
                let row = i / columns
                return Particle(position: CGPoint(x: bounds.minX + diameter + CGFloat(i % columns) * diameter + CGFloat(row % 2) * radius,
                                                  y: bounds.minY + radius + 0.001 + CGFloat(row) * rowHeight), radius: radius)
            }, bounds: bounds)
        }
        let window = pileWindow(in: bounds)
        let columns = max(1, Int((window.width - 40) / diameter))
        return ParticleEngine(particles: (0..<count).map { i in
            if CommandLine.arguments.contains("--compressed-pile-fixture"), i < min(count, 900) {
                return Particle(position: CGPoint(x: window.midX, y: window.maxY + radius + 0.001), radius: radius)
            }
            let row = i / columns
            return Particle(position: CGPoint(x: window.minX + 20 + CGFloat(i % columns) * diameter + CGFloat(row % 2) * radius,
                                              y: window.maxY + radius + 0.001 + CGFloat(row) * rowHeight), radius: radius)
        }, bounds: bounds)
    }
}
