import Foundation
import CoreGraphics
#if SWIFT_PACKAGE
import LayoutCore
#endif

/// CPU physics benchmark using synthetic geometry only.
enum ParticleBenchmark {
    static func run() {
        let count = LaunchArguments.value("--count", default: 3_000)
        let frames = LaunchArguments.value("--frames", default: 1_440)
        let withWindows = CommandLine.arguments.contains("--window-fixtures")
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let engine = ParticleEngine.rain(count: count, bounds: bounds, radius: LaunchArguments.ballRadius)
        engine.maximumSpeed = LaunchArguments.ballSpeed
        engine.update(at: 0)
        var times: [Double] = [], phases: [[Double]] = [[], [], []]
        var candidates = 0
        for frame in 1...frames {
            let time = Double(frame) / 120
            if frame % 12 == 1 { engine.collisionShapes = SyntheticFixtures.fixtures(in: bounds, time: time) }
            let start = ProcessInfo.processInfo.systemUptime
            SyntheticFixtures.updateMotion(in: engine, time: time)
            if withWindows, frame % 2 == 1 { engine.windowObstacles = SyntheticFixtures.windowFixtures(in: bounds, time: time) }
            engine.update(at: time)
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            times.append(elapsed)
            phases[min(2, (frame - 1) * 3 / frames)].append(elapsed)
            candidates = max(candidates, engine.candidateChecks)
        }
        PerformanceReport.printJSON(["mode": "physics", "particles": count, "frames": frames, "simulationHz": 240,
                   "maximumSpeed": engine.maximumSpeed, "ballRadius": LaunchArguments.ballRadius,
                   "deviceMotion": CommandLine.arguments.contains("--motion-fixture"),
                   "integrationSubsteps": engine.integrationSubsteps,
                   "windowObstacles": engine.windowObstacles.count,
                   "frameBudgetMs": 1000.0 / 120, "cpuMs": PerformanceReport.summary(times),
                   "phaseCpuMs": phases.map(PerformanceReport.summary), "peakCandidateChecks": candidates,
                   "finite": engine.particles.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite },
                   "framesOverBudget": times.filter { $0 > 1000 / 120 }.count])
    }
}
