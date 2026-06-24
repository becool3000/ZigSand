# ZigSand Stack Specification

Status: implemented baseline  
Target: Windows x64, AMD Radeon RX 5700 XT or equivalent Vulkan 1.3 GPU

## 1. Product boundary

ZigSand is a GPU-owned, deterministic falling-sand sandbox. The CPU manages the window, input, scheduling, resource lifetime, and compact tick parameters. It does not simulate cells, retain a mirrored world, colorize frames, or read the world grid back from the GPU.

The baseline materials are Empty, Sand, Water, Stone, Steam, and Cloud. Simulation and rendering share one canonical GPU cell buffer.

## 2. Pinned stack

| Layer | Required technology | Version or contract |
|---|---|---|
| Language and build | Zig | 0.16.0 |
| Platform | Native Win32 | Windows 10/11 x64 |
| Graphics and compute | Vulkan | API 1.3 minimum |
| Shader language | HLSL | Compute Shader Model 6.6; graphics Shader Model 6.0 |
| Shader compiler | Microsoft DXC | 1.9.2602.24 |
| Shader output | SPIR-V | Vulkan 1.3 target environment |
| Vulkan bindings | `vulkan-zig` | Commit `b496a6a561ffbbeb530b0f9ed4e059f88c0723a5` |
| Vulkan registry | Vulkan-Headers | Commit `8864cdc896bbc2a9b6eb36b3218fc9ef57908d77` |
| Windowing | Win32 API | No SDL, GLFW, engine, or UI framework |

Zig and DXC are installed project-locally under `.tools/` by `tools/bootstrap.ps1`. Downloads must match the SHA-256 values in that script. Zig package dependencies must remain content-hash pinned in `build.zig.zon`.

## 3. Build interface

The supported commands are:

```powershell
.\tools\bootstrap.ps1
zig build
zig build run -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseFast
zig build benchmark -Doptimize=ReleaseFast
```

`zig build` must compile every HLSL entry point with:

```text
-spirv -fspv-target-env=vulkan1.3 -fvk-use-dx-layout -WX -O3
```

SPIR-V must be generated in the Zig cache and embedded into the executable. Shader warnings are build failures.

## 4. Component ownership

| Component | Responsibility | Must not own |
|---|---|---|
| `src/win32.zig` | Native window, input events, client size, title | Vulkan or simulation state |
| `src/vk_context.zig` | Loader, instance, surface, device, queue, capability checks | Swapchain or cell rules |
| `src/gpu_sim.zig` | World buffers, activity lists, compute pipelines, tick submission, timings | Window or presentation state |
| `src/renderer.zig` | Swapchain, image views, graphics pipeline, direct rendering | Cell copies or simulation rules |
| `src/app.zig` | Runtime modes, fixed-tick scheduling, controls, tests, benchmark | Per-cell CPU state |
| `src/abi.zig` | Packed-cell and push-constant contracts | Vulkan object lifetime |
| `src/material.zig` | Stable material IDs, immutable specs, registry validation | Per-cell evolving state |
| `shaders/sim.hlsl` | All material behavior and GPU validation | Presentation policy |
| `shaders/render.hlsl` | Cell palette and letterboxed fullscreen rendering | Simulation mutation |

Platform-specific handles must not leak beyond `win32.zig`, `vk_context.zig`, and the small surface creation interface between them.

## 5. Required Vulkan capabilities

Startup must require:

- Vulkan API 1.3 or newer.
- A queue family supporting graphics and compute.
- Presentation support on that same queue for interactive mode.
- `VK_KHR_surface`, `VK_KHR_win32_surface`, and `VK_KHR_swapchain` when interactive.
- Vulkan 1.3 `synchronization2` and `dynamicRendering` features.
- Storage buffers and indirect compute dispatch.
- Graphics-and-compute timestamp queries.

Missing required capabilities must terminate startup with a specific diagnostic. `VK_LAYER_KHRONOS_validation` and `VK_EXT_debug_utils` are optional: request them with `--validation`, warn if unavailable, and continue without them.

The baseline uses one graphics/compute/present queue. Async compute is outside this specification until profiling justifies it.

## 6. Cell ABI

Every logical or padded cell occupies exactly one `u32`:

| Bits | Meaning |
|---|---|
| 0–7 | Material ID |
| 8–15 | Deterministic visual variant |
| 16–23 | Material flags |
| 24–31 | Reserved; write zero |

Material IDs are stable:

```text
0 Empty
1 Sand
2 Water
3 Stone
4 Steam
5 Cloud
```

Changing IDs, buffer element widths, push-constant fields, or structure packing is an ABI change and requires matching Zig and HLSL edits plus ABI tests.

Each valid material also has one immutable 32-byte `MaterialSpec`, indexed by its stable ID in a 256-entry GPU table. It stores packed phase/mobility/flags, four-bit dynamics traits, integer density and resistance, milli-degree Celsius defaults and ignition threshold, heat capacity, and a future reaction-table range. The dynamics traits are friction, motion decay, pressure response, disturbance decay, and surface response. Water consumes pressure response and emits slowly decaying surface disturbance; Sand blocks pressure; Steam and Cloud use gas phase/mobility with friction controlling movement cadence. Current temperature, charge, and other evolving values require separate canonical GPU channels. Cloud age is small material-local state and occupies the existing cell flags byte.

## 7. World memory contract

- Logical dimensions default to 1920×1080.
- Storage dimensions are independently rounded up to multiples of 16.
- Coordinates outside the logical world are treated as Stone.
- The three core grids are canonical cells, scratch cells, and packed movement proposals.
- Each grid uses four bytes per padded cell.
- Core grid storage at 1920×1080 must remain below 32 MiB; the current layout is 23.906 MiB.
- The canonical grid is never globally swapped or copied for presentation.
- MotionChannel is optional canonical `u32` storage: three direction bits, four strength bits, and zeroed reserved bits.
- Enabled MotionChannel storage adds 7.969 MiB at 1920×1080 and has no second motion scratch grid.
- DisturbanceChannel is optional canonical `u32` storage: four energy bits and zeroed reserved bits.
- Enabled DisturbanceChannel storage adds 7.969 MiB at 1920×1080. Its proposals reuse the movement-intent grid after movement resolution, so there is no separate disturbance scratch allocation.
- PressureChannel is optional canonical `u32` storage: eight magnitude bits and zeroed reserved bits.
- Enabled PressureChannel storage adds 7.969 MiB at 1920×1080. Its proposals reuse the movement-intent grid before Disturbance; there is no pressure scratch allocation or standalone pressure-commit dispatch.
- Rendering reads canonical Cells, Motion, Disturbance, or Pressure directly according to the selected debug view.
- CPU readback is restricted to compact statistics and test result records.

No application heap allocation may occur during a normal simulation tick or rendered frame. Startup allocation and swapchain-only resize allocation are permitted.

## 8. Shader descriptor contract

Simulation descriptor set 0 contains sixteen storage-buffer bindings:

| Binding | Buffer |
|---:|---|
| 0 | Canonical cells |
| 1 | Scratch cells |
| 2 | Movement intents |
| 3 | Current activity flags |
| 4 | Current compact chunk list |
| 5 | Current active count |
| 6 | Current indirect dispatch arguments |
| 7 | Next activity flags |
| 8 | Next compact chunk list |
| 9 | Next active count |
| 10 | Next indirect dispatch arguments |
| 11 | Compact GPU test result |
| 12 | Read-only material specifications |
| 13 | Optional canonical MotionChannel, or a one-word dummy binding when disabled |
| 14 | Optional canonical DisturbanceChannel, or a one-word dummy binding when disabled |
| 15 | Optional canonical PressureChannel, or a one-word dummy binding when disabled |

The renderer exposes four read-only storage buffers at set 0: canonical Cells at binding 0, Motion at 1, Disturbance at 2, and Pressure at 3. Rendering must not bind scratch, intent, or activity buffers. `RenderPush` carries the same enabled-channel bitmask as simulation; disabled debug channels render as zero-valued layers so one-word dummy bindings are never indexed past element zero.

`SimPush` is 64 bytes and `RenderPush` is 48 bytes. All fields are 32-bit values with identical Zig/HLSL ordering.

## 9. Tick pipeline

Chunks and compute workgroups are 16×16 cells. A fixed simulation tick executes in this order:

1. Clear next activity flags, count, and X indirect argument.
2. Apply an optional compact brush command to canonical cells.
3. Activate the painted chunk and its one-chunk halo in current and next lists.
4. Dispatch `IntentMain` indirectly over the compact current list; proposals contain direction plus accepted/rejected Motion outcomes.
5. Barrier compute writes before resolution reads.
6. Dispatch `ResolveMain` indirectly over the same current list and commit destination-owned Motion after all channel reads have completed.
7. Barrier resolved scratch and Motion writes before layered-channel reads.
8. Dispatch `PressureMain` over current active chunks. It gathers from resolved topology and canonical PressureChannel into the now-free movement-intent grid.
9. Barrier Pressure proposals before `DisturbanceMain`, which commits destination-owned Pressure and then reuses the same grid for marked Disturbance proposals.
10. Barrier scratch, layered proposals, and activity writes before commit.
11. Dispatch `CommitMain` indirectly over current active chunks only; it commits cells, participating Disturbance proposals, and destination-owned atmosphere phase changes in one pass. If Disturbance is disabled, this pass directly commits Pressure proposals instead.
12. Copy the next active count into its four-byte asynchronous statistic slot.
13. Swap current/next activity roles on the host; never swap cell grids.

The simulation rotates three preallocated command-buffer, fence, timestamp-query, and statistic slots. Timing collection may wait only when reusing an in-flight slot; it must not use query-result `WAIT` behavior.

## 10. Movement and determinism

Supported intents are Stay, Down, DownLeft, DownRight, Left, Right, and Up. Up is emitted only by gas mobility.

- Powder mobility attempts Down first, then one valid diagonal; Sand is the first material using this trait-driven path.
- Sand's short-lived Motion biases a valid diagonal after an avalanche begins. Accepted tendency lasts several moves, while rejection or forced redirection damps much faster than Water.
- Water attempts Down first, then one valid horizontal side.
- Water's nonzero Motion direction biases valid lateral choices; accepted motion decays by `motion_decay`, while rejection or redirection also applies `friction`.
- Motion never permits an otherwise invalid cell move, and fully blocked motion decays to zero so chunks can sleep.
- Surface Water gathers unsigned Disturbance energy from itself and horizontal surface neighbors. Local Motion emits energy according to `surface_response`; `disturbance_decay` removes it deterministically.
- Disturbance may perturb Water's deterministic preferred side, but it never changes occupancy validity, collision priority, or the one-cell-per-tick limit. Non-Water cells clear the channel.
- Water Pressure is an unsigned 0–255 body channel. Empty-above surface cells release it; submerged cells gather attenuated lateral/lower values and build head from Water above using `pressure_response`.
- Pressure gradients may bias Water's existing valid lateral choice. Pressure never creates upward movement, compression, duplication, or direct neighbor writes.
- Steam attempts Up first, then deterministic horizontal spreading. Cloud uses the same gas rule at a slower friction-derived cadence.
- Density-aware swaps let Sand displace lower-density Water, Steam, and Cloud; let lower-density gas rise through Water and powder; and let denser Water fall through Steam or Cloud without changing total material count.
- Supported surface Water uses an integer `(cell, tick, seed)` hash for 1-in-1024 evaporation. Steam becomes Cloud in the upper eighth; Cloud age advances once per 32 ticks and produces Water after 120–247 age steps.
- Surface-Water and atmospheric chunk halos remain active for scheduled evaporation and age progression; unrelated static chunks still sleep.
- Stone and Empty emit Stay.
- Movement is limited to one cell per tick.
- Sand may target Water and lower-density gas.
- If targeted Water does not successfully leave, it is displaced into the Sand source.
- If targeted Water successfully leaves, the Sand source becomes Empty.

Resolution is destination-centric. Each destination gathers the bounded neighboring sources whose intents target it. The winner is the minimum lexicographic key:

```text
(integer_hash(source_index, tick, seed), source_index)
```

Simulation decisions use integer operations only. Atomic append order, workgroup scheduling, and queue timing must never decide cell results. Atomic compare/exchange is permitted only for duplicate-free chunk activation.

Losing valid intents remain active for another tick. Movement, painting, and boundary-crossing changes activate the affected chunk and a one-chunk halo. Fully blocked and unchanged chunks must naturally sleep.

## 11. Rendering contract

- Render with one fullscreen triangle and Vulkan dynamic rendering.
- Read canonical Cells, Motion, Disturbance, and Pressure directly as storage buffers in the fragment shader.
- Cycle a zero-readback heatmap/debug view without modifying simulation state.
- Use integer nearest-cell addressing; no filtered cell texture.
- Preserve the world aspect ratio with centered letterboxing.
- Apply a CPU-owned camera center and zoom in the fragment shader; simulation coordinates and brush mapping use the same transform.
- Convert the simulation's bottom-left Y axis to Win32's top-left presentation orientation.
- Recreate only swapchain-dependent resources on resize or out-of-date results.
- Rendering cadence is independent of fixed simulation ticks.

Presentation uses per-swapchain-image completion semaphores so a binary semaphore is not reused before that image is reacquired.

## 12. Runtime interface

```text
--width N          logical world width; default 1920
--height N         logical world height; default 1080
--tps N            fixed ticks per second; default 60
--seed N           deterministic integer seed
--validation       request validation and debug-utils
--uncapped         saturate simulation while preserving presentation headroom
--benchmark N      headless benchmark duration in seconds
--gpu-tests        headless shader validation mode
```

Interactive input:

| Input | Action |
|---|---|
| Left mouse | Paint selected material |
| Right mouse | Erase to Empty |
| `1`, `2`, `3` | Select Sand, Water, Stone |
| Mouse wheel | Brush radius 1–64 |
| Space | Pause/resume |
| Period | One paused tick |
| `C` | Clear world |
| `R` | Restore demo scene |
| `T` | Toggle uncapped simulation |
| `V` | Cycle Cells/Motion/Disturbance/Pressure view |
| `E` / `Q` | Zoom in / out |
| `WASD` | Pan the camera |
| Escape | Exit |

Input commands apply at the next tick boundary. The runtime may execute at most four catch-up ticks per rendered frame, then must discard excess accumulated time.

Uncapped mode remains opt-in during tuning but is the intended eventual default presentation. Atmospheric rates are defined in ticks, so uncapped mode reaches the same deterministic cloud/rain equilibrium faster rather than skipping simulation states.

## 13. Test specification

Host tests must cover:

- Packed-cell and push-constant ABI sizes.
- Cell bit packing.
- CLI defaults, parsing, and bounds.
- Aligned device-memory layout arithmetic.
- Letterboxed coordinate mapping.
- Shader manifest completeness and embedded SPIR-V discovery.
- Material-spec size, offsets, trait encodings, stable IDs, duplicate rejection, and reaction ranges.
- Packed Motion and movement-proposal ABI values.
- Packed Disturbance ABI values.
- Packed Pressure ABI values.

Headless GPU tests must read back only the compact result structure and must verify:

- Sand falls exactly one cell.
- Blocked Sand remains stationary.
- Sand chooses the deterministic diagonal.
- Water falls before spreading.
- Water chooses the deterministic side.
- Sand displaces stationary Water without changing counts.
- Sand entering leaving Water does not duplicate materials.
- Contention selects the exact deterministic winner.
- Stone never moves.
- Sleeping chunks remain asleep and hash-stable across repeated ticks.
- Movement and painting across chunk boundaries wake neighbors.
- Active lists contain no duplicate or out-of-range IDs.
- Non-multiple-of-16 worlds retain solid padded boundaries.
- A cross-chunk collision scenario produces identical hashes, counts, and active count across 100 independent reset/replay runs.
- The determinism state hash processes canonical Cells, MotionChannel, DisturbanceChannel, then PressureChannel in that fixed order, with separate component hashes retained in the compact result.
- A falling-Water basin fixture retains material counts, exercises lateral Motion, and produces stable layered hashes over 100 resets.
- A falling-Sand shelf fixture retains material counts, exercises diagonal Motion, and produces stable layered hashes over 100 resets.
- A shallow Water basin fixture emits and propagates surface Disturbance and produces stable Cells/Motion/Disturbance hashes over 100 resets.
- A deep Water basin fixture builds nonzero integer head pressure while retaining material counts and produces stable four-layer hashes over 100 resets.
- Supported Water deterministically converts to Steam without losing H2O mass.
- Steam rises exactly one cell and aged Cloud converts to Water.
- A mixed Water/Steam/Cloud fixture conserves total H2O and produces identical layered hashes and material counts over 100 resets.
- Sand displaces Steam and Steam escapes through a narrow Sand cap without losing Sand or Steam count.
- 8192-tick atmosphere replays preserve total H2O in both the default world and a compact Water/Steam/Cloud fixture.
- Pressure-only and Disturbance-only channel configurations exercise their separate commit-owner branches.
- Disabling MotionChannel, DisturbanceChannel, and PressureChannel preserves cell-only behavior with one-word dummy buffers.

## 14. Performance acceptance

On the RX 5700 XT at 1920×1080:

- Fully active simulation must sustain 60 TPS.
- p95 GPU simulation time must be at most 16.67 ms.
- Fully active indirect group count must equal the compact active count.
- Core cell/intent storage must remain below 32 MiB.
- Interactive painting at chunk boundaries must remain responsive.
- No full-grid CPU readback or frame-loop heap allocation is permitted.
- Validation must report no errors when the validation layer is installed.

Benchmark mode must force every chunk active, warm up for two wall-clock seconds, measure for ten seconds by default, and report sample count, median, p95, and active/total chunks.

The RX 5700 XT fully active atmosphere build measures 0.780 ms median and 0.798 ms p95 for 8160/8160 chunks (11,069 samples after warmup). These measurements are evidence, not portable guarantees, and remain far below the 16.67 ms acceptance ceiling.

## 15. Deferred stack changes

The following require a new or revised specification before implementation:

- Linux windowing and presentation.
- Separate async-compute queues.
- Timeline-semaphore multi-frame presentation.
- UI framework adoption.
- Temperature, fire, reactions, compressible fluids, upward Water motion, or continuous fluids.
- Wave-intrinsic, block-movement, or alternate atomic kernels.
- GPU replay/capture formats.

Any optimized simulation kernel must pass the existing deterministic hashes and material-count tests before replacing the baseline.
