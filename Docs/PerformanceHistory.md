# Historical performance measurements

These are dated measurements, not current performance guarantees. Refer to the
[README](../README.md#test-without-desktop-access-or-recording) for current commands.
Artifact paths below are relative to the repository root and refer to ignored local build output.

### Radius-independent speed (2026-09-24)

The 100–500 points/sec speed setting replaces the old radius-dependent cap.
At the highest speed, small balls use three integration substeps per 240 Hz tick,
medium balls use two, and large balls use one. The twenty GPU contact passes per
tick are shared across those substeps (7/7/6 for small balls), retaining the
existing neighbor cache and avoiding a threefold increase in contact work.

On the Apple M2, `Scripts/check-particle-speeds.sh` passed all 18 combinations of
rain/cannon, radii 1.5/3/4.5 and speeds 100/300/500, plus five 10,000-ball stress
fixtures. Each met the 8.33 ms p95 offscreen serial-frame budget, including every
squeeze phase, and passed finite-state, wall/window-clearance, speed-limit and
render checks. The matrix's highest p95 was **6.12 ms**. Cannon fixtures include
slot reuse and window-induced despawning; their timings are not comparisons at
identical active populations.

With 10,000 small balls and twelve moving windows, the old 180-point/sec cap
measured **5.79 ms p95**, while the new 500 setting measured **5.76 ms** in the
first run and **5.60 ms** in the matrix. Both retained all balls. At speed 500,
the stationary pile and fast-drag fixtures also retained all 10,000 balls; the
matrix measured **1.79 ms** and **2.62 ms p95**, respectively. The stationary
pile's largest movement during its final second was **0.0048 points per frame**.
Squeezing measured **5.00 ms p95** during compression, recovering to **0.94 ms**
while held closed after retiring the trapped balls. These are synthetic,
offscreen results, not guarantees for real desktop presentation.

CPU reference runs at speed 500/radius 1.5 and speed 100/radius 4.5 also passed
simulation/render checks. A separate high-speed pile run with Metal API and
shader validation reported no errors. Reports and logs are in
`build/speed-checks/`.

### Earlier CPU solver measurements (M2 MacBook Air, 2026-09-10)

With 3,000 particles and 1,440 offscreen frames at 2880 × 1800: CPU physics p95 **6.98 ms**, GPU p95 **0.63 ms**, serial frame p95 **7.85 ms**, p99 **8.24 ms**. 11 frames exceeded 8.33 ms (maximum 9.00 ms), so this is a 120 fps budget target, not a guarantee of zero dropped frames. A 20-second window run presented **60.00 fps** on the built-in 60 Hz panel, with zero skipped submissions or GPU errors. At 60 Hz the solver performs four fixed steps per frame; at 120 Hz it performs two.

5,000 particles remain available as a stress setting, but dense piles exceeded the budget on this machine. No desktop scan or screen recording was used for these measurements. The full local results are in `build/particle-checks/{physics,metal,window}.json`.

### Window collision measurements (2026-09-11)

On the same M2, a 10-second production-timer probe completed **59.61 geometry polls/second**, with query p95 **1.32 ms**. With a separate 3,000-ball rounded-window sandbox rendering concurrently, it completed **60.10 polls/second**, with refresh-interval p95 **19.03 ms** (maximum **32.40 ms**). These are local measurements, not a guaranteed minimum on other desktops.

With the macOS 27 continuous profile, the 12-moving-window offscreen fixture at 2880 × 1800 measured serial frame p95 **9.27 ms**, within a 30/60 fps processing budget but above the 8.33 ms target for 120 fps. A 15-second continuous-profile sandbox run presented **59.87 fps** on the 60 Hz panel, with zero skipped submissions or GPU errors. Reports: `build/window-{metal,sandbox}-continuous.json`; geometry polling results remain in `build/window-geometry-rounded.json`. The Xcode Release app also built and passed code-signature verification.

### Earlier GPU optimization follow-up (2026-09-11)

The original Metal path accelerated drawing only; physics ran on the CPU. The GPU rewrite moved integration and contact solving into compute kernels, retained simulation state on the GPU for drawing, added spatial hashing and reusable neighbor lists, and cached exposed window-union boundaries on geometry changes. The CPU solver remains available for comparison.

Reference projects informed the architecture, not a direct port of their physics: `../../code-cloned/FluidDynamicsMetal` demonstrates GPU-resident ping-pong simulation passes and rendering through one command buffer (its fluid solver uses texture/render passes). `../../code-cloned/moleqular` compares all-pairs, cell-list, BVH and clustered Metal approaches; its local-neighbor approach and benchmark-driven comparisons guided the spatial hash/cache design. Neither fluid-grid physics nor Lennard-Jones molecular forces directly solve our hard-circle/window contacts.

**Issue observed before the compression fix below:** after roughly one to three minutes, dragging windows with balls on them could become slow. Upward motion was worst, but horizontal dragging also triggered it. Removing and respawning balls temporarily reset the problem. The initial diagnostics counted neighbors without recording where crowding occurred.

The first desktop capture showed extreme neighbor density and up to sixteen catch-up substeps, with sampled GPU frames exceeding 300 ms while memory stayed roughly flat. That follow-up added two-dimensional separation for coincident contacts, capped catch-up at four substeps, and added opt-in desktop diagnostics and performance fixtures. The later desktop capture respected the four-step cap but still reached **83.43 ms sampled GPU time** and **2,312 peak neighbors**. The issue was only partially mitigated at that point; these separate interactive sessions were not a controlled before/after speed comparison.

Latest synthetic checks on the M2: the 3,000-ball, two-minute simulated pile-drag run measured **1.56 ms p95 serial frame time**; 10,000 balls with twelve moving windows measured **5.14 ms**. Both passed finite-state and wall/window-clearance checks. The coincident-pile test reduced cumulative overflowing neighbor lists from 105,263 to 76,009, but its initial GPU spike remained. Metal API/GPU validation and the Xcode Release build/code-signature check passed. These results do not establish that prolonged real-desktop dragging is smooth. Local reports are under `build/performance/`, including `desktop-lag-before.jsonl`, `desktop-profile-after.jsonl`, `pile-drag-after.json` and `windows-10000-after.json` (not committed).

### Pile stability and compression despawning (2026-09-12)

The new stationary fixture reproduced a deep pile that remained in motion despite having no moving obstacles. Contact impulses accumulated from the same old velocity, while position projection left the downward velocity driving balls into neighbors. Normalizing simultaneous responses and feeding separation back into velocity stabilizes the pile without increasing the iteration count.

The old overflow path searched entire hash chains for every overcrowded ball on every contact iteration. A crushed cluster could therefore remain expensive even after window movement stopped. There was also no invalid-state retirement: invisible nonfinite balls could remain in the simulation. The new solver caps neighbor construction at 512 linked entries per ball and stops as soon as it observes a 49th neighbor; contact solving never falls back to an unbounded grid scan. Despawning invalidates the cache for the next pass, excludes the ball from grid insertion and contacts, and clips its render instance. Fixed buffer slots are retained until the shower is reset, with only constant work for each retired slot.

The production Metal solver uses these explicit rules:

- More than 45% diameter overlap counts as pressure only when opposing window/desktop constraints are detected within 32 ball radii. Pressure or cache saturation must persist for 0.1 simulated seconds; the timer resets when both clear. This is a local geometric heuristic, not a physical pressure measurement.
- A valid nearest window exit permits recovery regardless of travel distance. Deep penetration reflects into free space when possible, preserving spacing between swept rows instead of projecting all of them onto one edge. If the nearest exit is blocked, recovery to an exposed union edge is limited to eight ball radii; no nearby exit despawns the trapped ball.
- Neighborhood construction remains capped at 48 cached contacts and 512 linked entries. Saturated lists solve their stored contacts during the recovery interval, with their actual stored count kept separately from overflow flags. Sustained search-budget exhaustion is reported separately because hash collisions also consume the budget.
- Nonfinite or numerically unsafe state is retired before it can enter the grid or propagate through later contacts. Shader fast math is disabled so numerical guards remain effective; speed is bounded after contact solving as well as integration.

These are visual-simulation strain and workload thresholds, not forces measured in newtons. The optional `--cpu-physics` backend remains the original reference solver for comparison; these stability and despawning rules apply to the default Metal backend.

The fast-drag correction removes two false crushing signals from the original rules: arbitrary obstacle displacement and unconstrained pair overlap. At the default radius, the old eight-radius cutoff was only 12 points, easily exceeded between 60 Hz window samples even though physics runs at 240 Hz. Collapsing swept rows onto one edge also manufactured deep overlap and overflowing neighbor lists. Polling remains at 60 Hz; collision recovery and pressure classification now handle those discrete updates.

After this correction, the full performance script passed. The 12-second, 10,000-ball drag fixture retained all balls, versus 3,440 deletions before the fix. A two-minute simulated run at four vertical cycles per second with 30 Hz geometry sampling also retained all 10,000 balls, with **2.61 ms p95 serial frame time**, no invalid state, and no wall/window-clearance violations. The squeeze fixture still retired the trapped population, with **5.05 ms p95 during compression** and **1.24 ms while held closed**. Metal API/GPU validation reported no errors in a separate fast-drag run. Reports are in `build/particle-checks/` and `build/drag-fix/` (not committed). These are offscreen checks; real desktop dragging was not measured in this follow-up. The measurements below predate this correction.

On the M2, the 10,000-ball stationary fixture retained every ball: serial-frame p95 fell from **7.75 ms to 2.06 ms**, and p95 particle speed fell from **139.08 to 1.02 points/second**. In that run's final second, the largest per-frame position change stayed below **0.001 points**; a repeat without profiling reached **0.015 points**, still well below a pixel. Under extreme pile height the iterative solver still permits some compression (p95 pair overlap about 15% in this fixture).

The no-exit squeeze fixture despawned the trapped balls and recovered while the window remained closed: p95 was **5.77 ms during compression**, **0.96 ms while held closed**, and **0.95 ms after release**, with no invalid-state despawns. The earlier implementation reached a **50.64 ms maximum** in this fixture. The coincident fixture retired exactly the 900 coincident balls and retained the other 9,100. Reports: `build/performance/{settled-before,settled-final,squeeze-before,squeeze-final,coincident-final}.json`. These synthetic checks do not establish a guaranteed frame rate on every real desktop.

The full performance script passed, including all 10,000 balls surviving the ordinary 12-moving-window fixture (p95 **5.51 ms**). A two-minute, 10,000-ball fast-drag fixture passed at **1.96 ms p95**, with 3,443 compression despawns and 6,557 survivors; its timing is not a same-population comparison to earlier runs. Metal API/GPU validation reported no errors in the squeeze fixture, and the Xcode Release build and code-signature verification passed. Validation instrumentation is excluded from performance-budget measurements.

A later squeeze repeat passed simulation/render checks but missed the compression-phase 120 Hz budget: **8.39 ms p95** versus 8.33 ms. It still recovered to **1.95 ms while held closed** and **2.91 ms after release**. This variation is retained in `build/performance/squeeze-render-final.json`; the fix bounds collision work and retires crushed balls, but does not guarantee 120 fps under all system loads.
### Cursor collisions (2026-09-24)

Cursor contacts use 48 bytes of additional Metal parameters, independent of static geometry revisions. The swept capsule runs at most once per submitted physics frame in the existing integration kernel; a stationary cursor skips that work. Circle contacts use an axis-aligned rejection before distance calculations. No additional dispatches, geometry buffers or particle readbacks are introduced. Motion-triggered neighbor rebuilding uses the existing displacement check.

`Scripts/check-cursor-collisions.sh` adds reproducible off/on pile, window and CPU performance workloads. The cursor fixture includes stationary contact, slow stirring, rapid strokes and exit/re-entry. On Apple M2, the final 10,000-ball pile runs measured **5.06 ms p95 with cursor disabled** and **5.60 ms enabled**, retaining every ball. The 10,000-ball moving-window workload at speed 500 initially passed at 6.11 ms, then missed the 8.33 ms budget at **11.53 ms**. A subsequent control with the cursor disabled also missed at **12.29 ms**, while the enabled repeat measured **5.80 ms**. This variability prevents a precise overhead estimate or a claim of sustained desktop 120 fps. All runs retained all balls and passed finite-state, wall/window-clearance and speed checks. The CPU reference also passed its existing health checks (it has no 120 Hz performance gate).

Reports are under `build/cursor-checks/`, including `enabled-windows-budget-miss.json`, `disabled-windows.json` and `enabled-windows-repeat.json`; generated reports are not committed. Measurements are sequential offscreen runs, with other desktop applications running, not a live presentation benchmark.
