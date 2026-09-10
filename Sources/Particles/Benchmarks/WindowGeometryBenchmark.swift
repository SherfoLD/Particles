import Foundation

/// Explicit opt-in to measure real Window Server geometry, without reading
/// Finder or capturing screen contents. Uses the production background timer.
@MainActor
enum WindowGeometryBenchmark {
    static func run() {
        let tracker = WindowGeometryTracker()
        let duration = LaunchArguments.value("--duration", default: 10)
        tracker.start(collectMetrics: true)
        RunLoop.main.run(until: Date().addingTimeInterval(Double(duration)))
        let snapshot = tracker.snapshot
        tracker.stop()
        let elapsed = snapshot.lastSampleTime - snapshot.firstSampleTime
        let hz = elapsed > 0 ? Double(snapshot.samples - 1) / elapsed : 0
        PerformanceReport.printJSON([
            "mode": "window-geometry", "targetHz": 60, "measuredHz": hz,
            "samples": snapshot.samples, "windowCount": snapshot.rectangles.count,
            "queryMs": PerformanceReport.summary(snapshot.queryTimesMs),
            "refreshIntervalMs": PerformanceReport.summary(snapshot.intervalsMs),
            "meets30Hz": hz >= 30
        ])
        if CommandLine.arguments.contains("--require-30hz"), hz < 30 { exit(1) }
    }
}
