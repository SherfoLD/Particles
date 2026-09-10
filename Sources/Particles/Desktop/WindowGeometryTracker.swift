import Foundation
import CoreGraphics

/// Only geometry is inspected: no window titles, pixels, Accessibility or capture.
enum WindowGeometry {
    /// The overlay's Window Server bounds follow the Space's presentation offset.
    /// Comparing them with its fixed desktop bounds detects an interactive swipe
    /// before AppKit announces a change of active Space, including cancelled swipes.
    struct Anchor: Sendable {
        let windowID: CGWindowID
        let displayID: UInt32
        let frame: CGRect
    }

    static func stationaryDisplays(in windows: [[String: Any]], anchors: [Anchor]) -> Set<UInt32> {
        let anchorsByWindow = Dictionary(uniqueKeysWithValues: anchors.map { ($0.windowID, $0) })
        return Set(windows.compactMap { window in
            guard let id = window[kCGWindowNumber as String] as? UInt32,
                  let anchor = anchorsByWindow[id],
                  let visible = window[kCGWindowIsOnscreen as String] as? NSNumber, visible.boolValue,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  abs(rect.minX - anchor.frame.minX) < 0.25,
                  abs(rect.minY - anchor.frame.minY) < 0.25,
                  abs(rect.width - anchor.frame.width) < 0.25,
                  abs(rect.height - anchor.frame.height) < 0.25 else { return nil }
            return anchor.displayID
        })
    }

    static func rectangles(from windows: [[String: Any]], excludingPID: Int32) -> [CGRect] {
        windows.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? NSNumber,
                  pid.int32Value != excludingPID,
                  let layer = window[kCGWindowLayer as String] as? NSNumber,
                  layer.int32Value == CGWindowLevelForKey(.normalWindow),
                  let alpha = window[kCGWindowAlpha as String] as? NSNumber,
                  alpha.doubleValue.isFinite, alpha.doubleValue > 0,
                  let visible = window[kCGWindowIsOnscreen as String] as? NSNumber, visible.boolValue,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.origin.x.isFinite, rect.origin.y.isFinite,
                  rect.width.isFinite, rect.height.isFinite, rect.width > 1, rect.height > 1 else { return nil }
            return rect
        }
    }

    /// Both arguments use Window Server's global top-left coordinates. Keep
    /// full bounds for intersecting windows: clipping would invent rounded
    /// corners where a straight window edge crosses the display boundary.
    static func localRectangles(_ rectangles: [CGRect], on display: CGRect) -> [CGRect] {
        rectangles.compactMap { rect in
            let intersection = rect.intersection(display)
            guard !intersection.isNull, !intersection.isEmpty else { return nil }
            return CGRect(x: rect.minX - display.minX, y: display.maxY - rect.maxY,
                          width: rect.width, height: rect.height)
        }.sorted {
            if $0.minX != $1.minX { return $0.minX < $1.minX }
            if $0.minY != $1.minY { return $0.minY < $1.minY }
            if $0.width != $1.width { return $0.width < $1.width }
            return $0.height < $1.height
        }
    }

    static func read(anchors: [Anchor]) -> (rectangles: [CGRect], stationaryDisplays: Set<UInt32>) {
        autoreleasepool {
            // Include the below-normal overlay anchors in the very same query as
            // the obstacles, so animated bounds cannot be paired with an old gate.
            guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly,
                                                          kCGNullWindowID) as? [[String: Any]] else { return ([], []) }
            return (rectangles(from: windows, excludingPID: ProcessInfo.processInfo.processIdentifier),
                    stationaryDisplays(in: windows, anchors: anchors))
        }
    }
}

/// One serial 60 Hz poller for all displays. Window Server IPC never runs in a
/// render callback. A slow query coalesces timer ticks instead of queuing work.
@MainActor
final class WindowGeometryTracker {
    struct Snapshot: Sendable {
        var rectangles: [CGRect] = []
        var revision: UInt64 = 0
        var stableDisplays: Set<UInt32> = []
        var spaceRevision: UInt64 = 0
        var samples = 0
        var firstSampleTime: Double = 0
        var lastSampleTime: Double = 0
        var queryTimesMs: [Double] = []
        var intervalsMs: [Double] = []
    }

    /// All mutable worker state is protected by this lock. It is held only to
    /// exchange value snapshots, never during Window Server IPC.
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Snapshot()
        private var generation: UInt64 = 0
        private var stationarySamples: [UInt32: Int] = [:]

        func reset() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            generation &+= 1
            value = Snapshot(revision: value.revision &+ 1, spaceRevision: value.spaceRevision &+ 1)
            stationarySamples.removeAll()
            return generation
        }

        func snapshot() -> Snapshot {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func publish(_ rectangles: [CGRect], stationaryDisplays: Set<UInt32>, generation expected: UInt64, started: Double,
                     finished: Double, collectMetrics: Bool) {
            lock.lock(); defer { lock.unlock() }
            guard generation == expected else { return }
            stationarySamples = stationarySamples.filter { stationaryDisplays.contains($0.key) }
            for display in stationaryDisplays {
                stationarySamples[display] = min(3, (stationarySamples[display] ?? 0) + 1)
            }
            // Reject the first moving sample immediately; resume only after three
            // settled samples, so crossing the origin mid-gesture cannot resume us.
            let stableDisplays = Set(stationarySamples.filter { $0.value >= 3 }.keys)
            if stableDisplays != value.stableDisplays {
                value.stableDisplays = stableDisplays
                value.spaceRevision &+= 1
            }
            if value.rectangles != rectangles {
                value.rectangles = rectangles
                value.revision &+= 1
            }
            if collectMetrics {
                value.queryTimesMs.append((finished - started) * 1000)
                if value.samples > 0 { value.intervalsMs.append((finished - value.lastSampleTime) * 1000) }
                if value.queryTimesMs.count > 16_384 { value.queryTimesMs.removeFirst(8_192) }
                if value.intervalsMs.count > 16_384 { value.intervalsMs.removeFirst(8_192) }
            }
            if value.samples == 0 { value.firstSampleTime = finished }
            value.lastSampleTime = finished
            value.samples += 1
        }
    }

    private let store = Store()
    private let queue = DispatchQueue(label: "dev.local.Particles.window-geometry", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    var snapshot: Snapshot { store.snapshot() }

    func start(anchors: [WindowGeometry.Anchor] = [], collectMetrics: Bool = false) {
        stop()
        let generation = store.reset()
        let store = store
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 60), leeway: .milliseconds(1))
        timer.setEventHandler { @Sendable in
            let started = ProcessInfo.processInfo.systemUptime
            let result = WindowGeometry.read(anchors: anchors)
            store.publish(result.rectangles, stationaryDisplays: result.stationaryDisplays,
                          generation: generation, started: started,
                          finished: ProcessInfo.processInfo.systemUptime, collectMetrics: collectMetrics)
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        _ = store.reset() // Reject an in-flight result from an earlier Space/run.
    }
}
