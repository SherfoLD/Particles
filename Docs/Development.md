# Developing Particles

## Build and run

The Xcode project builds the macOS menu bar app. Use a Release build for performance work:

```sh
xcodebuild -project Particles.xcodeproj -scheme Particles \
  -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Particles.app
```

You can also open `Particles.xcodeproj` in Xcode and run the `Particles` scheme. The Swift package builds the command-line executable used by the sandbox and benchmarks:

```sh
swift build -c release
.build/release/Particles --sandbox
```

The desktop app starts without balls. Use its menu bar icon to spawn them. It requests Desktop Folder access for icon artwork and Finder Automation access for icon positions. Denied access only removes file and folder collisions; widgets, windows, and the Dock have separate geometry sources. The sandbox and offscreen benchmarks do not request desktop permissions. Build products and reports under `build/` are ignored by Git.

## Code map

| Path | Responsibility |
| --- | --- |
| `Sources/LayoutCore/` | Particle state, collision geometry, CPU reference, and Metal simulation |
| `Sources/Particles/App/` | Entry point and menu bar lifecycle |
| `Sources/Particles/Desktop/` | Finder, widget, Dock, and window geometry; per-display overlays |
| `Sources/Particles/Rendering/` | Metal drawing and frame lifecycle |
| `Sources/Particles/Sandbox/` | Synthetic obstacles, scenarios, and interactive controls |
| `Sources/Particles/Benchmarks/` | Command-line performance runners |
| `Sources/Particles/Support/` | Launch arguments and performance reports |
| `Particles/`, `Particles.xcodeproj/`, `Package.swift` | App metadata, Xcode project, and Swift package |
| `Scripts/`, `Scenarios/` | Performance checks and example scenarios |

Keep desktop access in `Sources/Particles/Desktop/` so synthetic runs need no Finder or Window Server data. Xcode compiles both source directories into one target; SwiftPM builds `LayoutCore` separately, so its imports are conditional on `SWIFT_PACKAGE`.

## Runtime notes

- `DesktopReader` reads Finder icon positions and icon-view settings. `DesktopIconGeometry` traces the visible alpha outline of system icons and, when enabled, Quick Look previews. Results are cached; a failed artwork read omits a file collider. Folders have a standard silhouette fallback.
- `DockGeometryTracker` measures the Dock through `CoreDockGetRect` when available, then tries Window Server bounds. If both fail, Dock collisions are omitted. `CoreDockGetRect` is private macOS API and may change.
- `WindowGeometryTracker` samples normal application windows on a background timer targeting 60 Hz. Overlay positions help detect Space transitions. The per-display simulation pauses while its Space moves and resumes after geometry stabilizes.
- Metal runs a 240 Hz particle solver with a GPU spatial hash and draws particles from GPU buffers. The CPU solver remains available with `--cpu-physics` for comparison. Very dense or crushed particles can be despawned to keep work bounded.
- Each display has a transparent, click-through overlay beneath normal application windows. The cannon alone receives pointer input. Cursor collisions share the existing Metal update path and reset their stroke history after display or Space changes.

Collision geometry is best effort: Finder badges and some previews may differ from traced artwork; widget detection depends on macOS window metadata; custom window shapes and transparent regions are not traced. Window sampling can miss a very fast drag. See [Performance history](PerformanceHistory.md) for past measurements and optimization notes.

## Synthetic sandbox

The sandbox lets you add and move synthetic widgets, folders, icons, windows, and Dock shapes, set polling rates and delivery delays, and compare source geometry with the geometry received by physics. It does not read the real desktop.

```sh
.build/release/Particles --sandbox
.build/release/Particles --sandbox --scenario Scenarios/lift-window.json
.build/release/Particles --sandbox --duration 20 --sandbox-log build/sandbox.jsonl
```

`--scenario PATH` also works with `--render-benchmark`. Scenario coordinates use bottom-left canvas points, and frames are `[x, y, width, height]`. `spawnAt`, `removeAt`, and keyframe times are seconds from the start. Keyframes interpolate position and size, then hold the final frame. A scenario's `duration` defaults to 12 seconds; `--duration` overrides it in the sandbox.

```json
{
  "width": 1200,
  "height": 760,
  "duration": 10,
  "obstacles": [{
    "id": "lift",
    "type": "window",
    "frame": [400, 100, 350, 200],
    "spawnAt": 1,
    "removeAt": 9,
    "keyframes": [
      { "at": 3, "frame": [400, 100, 350, 200] },
      { "at": 6, "frame": [400, 400, 350, 200] }
    ]
  }]
}
```

Custom entries in `types` can inherit a built-in type and override `shape`, `hz`, `delayMs`, `radius`, or `points`. Available shapes are `widget`, `folder`, `icon`, `window`, `dock`, `rectangle`, `roundedRect`, `ellipse`, and `polygon`. A polygon needs 3–96 normalized `[x, y]` points. Only `shape: "window"` uses the window union solver. The sandbox's **Save current layout** exports a static scenario, including obstacle timing.

## Performance checks

Run these on an otherwise idle machine when comparing timings:

```sh
Scripts/check-particles.sh
Scripts/check-particle-speeds.sh
Scripts/check-cursor-collisions.sh
Scripts/check-synthetic-sandbox.sh
```

`Scripts/check-particles.sh --window` also opens a visible sandbox. Reports go under `build/`. The scripts exercise the CPU reference and Metal simulation, including moving windows, dense piles, cannon placement, speed and size combinations, and cursor strokes. Offscreen timing gates use an 8.33 ms p95 serial-frame budget; they do not establish visible 120 fps on a given display.

For an individual offscreen run or scenario replay:

```sh
.build/release/Particles --render-benchmark --count 3000 --frames 1440 \
  --snapshot build/particles.png --require-120fps
.build/release/Particles --render-benchmark --scenario Scenarios/lift-window.json \
  --sandbox-log build/lift-frames.jsonl > build/lift-report.json
```

`--sandbox-log` records source and delivered geometry, sample age, position error, and timing. `--profile-physics` emits GPU diagnostics. Instrumentation changes the workload, so compare performance using an uninstrumented run. `--ball-speed` and `--ball-radius` are available for sandbox and benchmark runs. `--window-benchmark --duration 10 --require-30hz` measures real window-geometry polling without Finder access.
