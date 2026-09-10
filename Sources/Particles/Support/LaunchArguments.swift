import Foundation
#if SWIFT_PACKAGE
import LayoutCore
#endif

/// Shared command-line values used by the app and developer tools.
enum LaunchArguments {
    static var ballSpeed: CGFloat {
        CGFloat(value("--ball-speed", default: Int(ParticleEngine.defaultMaximumSpeed)))
    }

    static var ballRadius: CGFloat {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--ball-radius"), index + 1 < args.count,
              let value = Double(args[index + 1]), [1.5, 3, 4.5].contains(value) else { return 1.5 }
        return CGFloat(value)
    }

    static func value(_ name: String, default fallback: Int) -> Int {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: name), index + 1 < args.count,
              let value = Int(args[index + 1]), value > 0 else { return fallback }
        return value
    }
}
