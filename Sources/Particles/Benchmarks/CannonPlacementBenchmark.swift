import Foundation
import CoreGraphics
#if SWIFT_PACKAGE
import LayoutCore
#endif

/// Exercises the production placement code without creating windows or reading
/// the desktop. Keep search timings separate so idle frames cannot hide stalls.
enum CannonPlacementBenchmark {
    static func run() throws {
        let frames = max(120, LaunchArguments.value("--frames", default: 360))
        var reports: [[String: Any]] = []
        var overBudget = false
        for size in [CGSize(width: 1440, height: 900), CGSize(width: 2560, height: 1440)] {
            let bounds = CGRect(origin: .zero, size: size)
            for scenario in ["unrelated-window", "nearby-relocation", "almost-covered", "fully-covered", "overlapping-cover", "recovery"] {
                var placement = CannonPlacement(bounds: bounds)
                var updates: [Double] = [], searches: [Double] = []
                var pendingFrames = 0, placedFrames = 0
                for frame in 0..<frames {
                    let phase = frame % 120
                    if phase == 0 {
                        placement = CannonPlacement(bounds: bounds)
                        placement.updateObstacles([], windows: [], cornerRadius: WindowCornerCurve.defaultRadius)
                    }
                    let overlap = [CGRect(x: 0, y: 0, width: size.width * 0.6, height: size.height),
                                   CGRect(x: size.width * 0.4 + sin(Double(frame)), y: 0,
                                          width: size.width * 0.6 + 2, height: size.height)]
                    let windows: [CGRect]
                    switch scenario {
                    case "unrelated-window":
                        windows = [CGRect(x: size.width * 0.65 + sin(Double(frame)), y: 100, width: 300, height: 500)]
                    case "nearby-relocation":
                        windows = [CGRect(x: size.width * 0.3 + sin(Double(frame)) * 4,
                                          y: size.height * 0.25, width: 300, height: 300)]
                    case "almost-covered":
                        windows = [CGRect(x: 0, y: 0, width: size.width - 100, height: size.height)]
                    case "fully-covered": windows = [bounds]
                    case "overlapping-cover": windows = overlap
                    default: windows = phase < 60 ? overlap : []
                    }
                    let wasSearching = placement.isSearching, oldOrigin = placement.origin
                    let start = ProcessInfo.processInfo.systemUptime
                    placement.updateObstacles([], windows: windows, cornerRadius: WindowCornerCurve.defaultRadius)
                    let shapes = placement.collisionShapes
                    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    updates.append(elapsed)
                    if phase == 0 || wasSearching || placement.isSearching || oldOrigin != placement.origin {
                        searches.append(elapsed)
                    }
                    if placement.isSearching { pendingFrames += 1 }
                    if !shapes.isEmpty { placedFrames += 1 }
                    // A performance result is invalid if searching was skipped or
                    // never finishes, or if an obstructed cannon remains visible.
                    if phase == 119 {
                        let shouldPlace = scenario != "fully-covered" && scenario != "overlapping-cover"
                        guard placement.isPlaced == shouldPlace else {
                            throw failure("Placement did not complete correctly for \(scenario)")
                        }
                    }
                }
                let updateSummary = PerformanceReport.summary(updates)
                let searchSummary = PerformanceReport.summary(searches)
                // Reserve most of an 8.33 ms frame for physics and rendering.
                if max(updateSummary["p95"] ?? 0, searchSummary["p95"] ?? 0) > 2 { overBudget = true }
                reports.append(["size": [Int(size.width), Int(size.height)], "scenario": scenario,
                                "updateMs": updateSummary, "searchFrameMs": searchSummary,
                                "pendingFrames": pendingFrames, "placedFrames": placedFrames])
            }
        }
        PerformanceReport.printJSON(["mode": "cannon-placement", "framesPerScenario": frames,
                                     "p95BudgetMs": 2, "meetsBudget": !overBudget, "scenarios": reports])
        if CommandLine.arguments.contains("--require-120fps"), overBudget {
            throw failure("Cannon placement exceeded its 2 ms p95 frame budget")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "CannonPlacementBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
