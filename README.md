# ZigSand

ZigSand is a GPU-first falling-sand foundation built with Zig 0.16, native Win32, Vulkan 1.3, and HLSL compute shaders compiled to SPIR-V. The GPU owns the canonical world; there is no CPU simulator, ASCII renderer, colorization texture, presentation snapshot, or full-grid readback.

The authoritative technology, ABI, runtime, and acceptance contracts are in [specs/STACK.md](specs/STACK.md).

## Requirements and setup

- Windows 10/11 x64
- A Vulkan 1.3 GPU/driver supporting synchronization2, dynamic rendering, swapchains, storage buffers, and timestamp queries
- PowerShell and the inbox `tar.exe`

The bootstrap script downloads checksum-pinned Zig 0.16.0 and Microsoft DXC 1.9.2602.24 into `.tools/`:

```powershell
.\tools\bootstrap.ps1
zig build test -Doptimize=ReleaseFast
zig build run -Doptimize=ReleaseFast
```

In later PowerShell sessions, run `. .\tools\env.ps1` before using `zig build`.

Useful commands:

```powershell
zig build                         # shaders + executable
zig build run -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseFast
zig build benchmark -Doptimize=ReleaseFast
```

Runtime options are `--width`, `--height`, `--tps`, `--seed`, `--validation`, `--uncapped`, `--benchmark <seconds>`, and `--gpu-tests`. `--uncapped` runs as many simulation ticks as fit while retaining a small rendering/input budget. It remains opt-in while the runtime is being tuned, but is the intended eventual default showcase experience. Validation is enabled only when `VK_LAYER_KHRONOS_validation` is installed; otherwise ZigSand logs a warning and continues.

## Controls

- Left mouse: paint the selected material
- Right mouse: erase
- `1`, `2`, `3`: Sand, Water, Stone
- Mouse wheel: brush radius, 1–64 cells
- Space: pause
- Period: advance one tick
- `C`: clear
- `R`: restore the demo scene
- `T`: toggle uncapped simulation
- `V`: cycle Cells, Motion, Disturbance, and Pressure GPU views
- `E` / `Q`: zoom in / out
- `WASD`: pan while zoomed
- Escape: quit

## Architecture

Each cell is one `u32`: material in bits 0–7, deterministic visual variant in bits 8–15, flags in bits 16–23, and reserved bits in 24–31. The canonical cell grid, scratch grid, and proposal grid consume about 24 MiB at 1920×1080. The optional canonical MotionChannel, DisturbanceChannel, and PressureChannel each add about 8 MiB. None needs a second channel-sized scratch grid: Pressure and Disturbance sequentially reuse the movement-proposal grid after movement resolution has finished reading it. Storage is padded to 16×16 chunks; out-of-world cells behave as Stone.

One fixed simulation tick executes:

1. Clear only next-list metadata.
2. Apply a compact brush command and wake its chunk halo.
3. Dispatch intent generation indirectly over the current compact active list.
4. Resolve destinations by gathering bounded source candidates and choosing the lowest deterministic integer `(hash, source_index)` key; commit winning Motion after all channel reads finish.
5. Gather the next Pressure value from the resolved scratch topology into the now-free movement-proposal grid.
6. Commit Pressure while gathering Disturbance into that same reused proposal grid.
7. Commit scratch cells, participating Disturbance proposals, and local atmosphere phase changes together, only for current active chunks.
8. Swap active-list handles, never the world grids.

Sand and Water move at most one cell per tick. Sand can displace stationary Water and lower-density gas, while Steam can rise through Sand by the same deterministic density-swap resolver. Water remains gravity-first and never moves upward, preventing pressure feedback from creating floating clumps. Steam rises and Cloud drifts using gas mobility; density swaps let vapor rise through Water and rain fall through gas. Workgroup-shared halo tiles reduce repeated global reads, atomic flag transitions prevent duplicate active chunks, and atomics never decide cell outcomes. Rendering reads canonical channel buffers directly in the fragment shader, including the zero-readback debug views.

### Trait-driven simulation systems

Materials are authored in Zig as validated, stable-ID `MaterialSpec` records and uploaded once to a small device-local GPU table. A spec contains immutable shared traits such as phase, mobility, density, conductivity, pressure behavior, default temperature, heat capacity, ignition threshold, and a future reaction-table range. Current temperature, pressure, charge, and other evolving values do not belong in the spec or packed cell; each future system will own an optional canonical GPU state channel.

Systems remain specialized GPU kernels that consume those traits. Contested state follows `propose -> gather -> deterministic resolve -> commit`, and each canonical channel has exactly one commit owner. If multiple systems can change cell material, they must submit to the same material-transition resolver. Determinism hashes cover canonical channels in a fixed order as those channels are added.

This migration is intentionally incremental. Sand movement and liquid displacement are selected from phase, mobility, and density; Steam and Cloud use generic gas mobility with friction controlling movement cadence. Rendering palettes and phase-change identities still use explicit material IDs. The host registry's `get`, `add`, `list`, and validation interfaces are the future seam for inspection and authoring tools, but ZigSand does not include MCP, runtime hot reload, or general debug readbacks yet.

### Layered channels

- **MotionChannel:** actual integer movement tendency. Water retains lateral flow, while Sand retains only a brief diagonal avalanche tendency. Motion influences proposals but never bypasses occupancy or collision resolution.
- **PressureChannel:** unsigned integer body pressure from 0–255. Open Water surfaces release it, connected Water gathers it, and `pressure_response` builds deterministic head with depth. Pressure gradients may bias an already-valid lateral choice, but Pressure never moves Water upward.
- **DisturbanceChannel:** short-lived unsigned surface energy from 0–15. Water Motion emits energy, connected surface Water gathers it laterally, and material-specific decay removes it. It can perturb Water's otherwise deterministic lateral preference, but it cannot make an invalid move valid. Sand and Stone absorb it.
- **Friction:** an immutable material trait that increases rejected-motion damping. `motion_decay`, `pressure_response`, `disturbance_decay`, and `surface_response` are packed integer traits. Water currently uses zero friction, slow motion decay, slow disturbance decay, and nonzero surface response; Sand uses moderate friction and quickly absorbs disturbance.

Motion is one packed `u32` per cell with a three-bit direction and four-bit strength. Each movement proposal stores accepted and rejected Motion outcomes plus a participation bit, so destination-centric resolution commits the correct value without material-table lookups or race-prone scatter writes. Sand now seeds a stronger diagonal tendency and preserves it for several accepted moves, while rejection still damps it much faster than Water.

Disturbance is also one `u32` per cell, currently using only four energy bits. It is deliberately not pressure, fluid velocity, or a wave-height solver. Pressure uses a separate `u32` with an eight-bit magnitude. Both use destination-owned gathers and one commit owner per enabled pipeline configuration, following the same `propose -> gather -> deterministic resolve -> commit` discipline as material movement. Determinism validation hashes canonical Cells, Motion, Disturbance, then Pressure in that fixed order.

### Deterministic atmosphere

Supported surface Water evaporates with a deterministic 1-in-1024 per-tick integer hash. Steam rises first and spreads sideways when blocked. Entering the upper eighth of the world converts it to Cloud. Cloud age lives in the existing cell-state byte, advances once every 32 ticks, and converts to Water after a variant-dependent threshold of 120–247 age steps. This slower age cadence lets clouds form a dense ceiling even in uncapped mode; uncapped simply reaches the same tick-defined equilibrium much faster in wall time. Water, Steam, and Cloud counts remain mass-conserving.

The test command runs host ABI/CLI/layout/coordinate/manifest tests plus shader-side GPU tests. GPU readback is limited to a 56-byte result record and a 4-byte active-count statistic. Disturbance, Pressure, Sand/Steam swaps, and mixed atmospheric fixtures are reset and replayed without reading back the grid. The atmosphere suite includes 8192-tick H2O mass-conservation replays for both the default world and a compact Water/Steam/Cloud fixture. Benchmark mode forces all chunks active, warms up for two wall-clock seconds, then measures for ten seconds by default.

## Layout

```text
build.zig / build.zig.zon  pinned build graph and dependencies
shaders/sim.hlsl           initialization, paint, intent, resolve, pressure, disturbance, commit, validation
shaders/render.hlsl        fullscreen direct cell/channel-buffer rendering
src/gpu_sim.zig            simulation buffers, descriptors, dispatch, GPU timing
src/renderer.zig           swapchain and Vulkan dynamic rendering
src/vk_context.zig         Vulkan loader, capability checks, device/queue ownership
src/win32.zig              isolated native window and input layer
src/abi.zig                Zig/HLSL ABI and packed-cell contract
src/material.zig           validated material schema and stable-ID registry
src/app.zig                interactive loop, GPU tests, benchmark
tools/                     checksum-verified local toolchain setup
```

## Best next step

Profile interactive painting with Vulkan validation and RenderDoc. The simulation already rotates three in-flight tick slots; the next architectural improvement is two or three presentation frames coordinated by timeline semaphores, followed by measured wave-intrinsic or block-movement kernel experiments. Keep the current deterministic kernels and GPU hashes as the correctness baseline.
