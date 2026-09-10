import AppKit

@main
@MainActor
enum ParticlesApp {
    static func main() {
        if CommandLine.arguments.contains("--scenario"),
           !CommandLine.arguments.contains("--sandbox"), !CommandLine.arguments.contains("--render-benchmark") {
            fputs("--scenario requires --sandbox or --render-benchmark\n", stderr); exit(1)
        }
        if CommandLine.arguments.contains("--icon-benchmark") { IconGeometryBenchmark.run(); return }
        if CommandLine.arguments.contains("--window-benchmark") { WindowGeometryBenchmark.run(); return }
        if CommandLine.arguments.contains("--cannon-placement-benchmark") {
            do { try CannonPlacementBenchmark.run() }
            catch { fputs("Cannon placement benchmark failed: \(error)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--render-benchmark") {
            do { try MetalBenchmark.run() }
            catch { fputs("Metal benchmark failed: \(error)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--benchmark") { ParticleBenchmark.run(); return }
        let application = NSApplication.shared
        let delegate: any NSApplicationDelegate = CommandLine.arguments.contains("--sandbox")
            ? ParticleSandboxDelegate() : ParticlesDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
