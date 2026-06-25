# DLL Optimization Plan

This document outlines optimization strategies for the injected DLL (`hook.dll`) to reduce CPU overhead during rollback states and memory snapshotting. The focus is on two primary performance bottlenecks: state snapshot memory copies (`memcpy`) and physics simulation reruns (fast-forward logic ticks).

---

## 1. Memory Snapshotting Optimizations (`memcpy`)

Currently, the DLL copies approximately 800 KB to 1 MB of memory per frame. While modern CPUs can handle this quickly, the current implementation performs about 370 individual `@memcpy` calls (one for each memory region) every frame.

### Strategy A: Contiguous Memory Region Coalescing (Merging)
* **Concept:** At startup (`onEnterInGame`), sort the list of memory regions by their memory addresses and merge adjacent or overlapping regions into single, larger blocks.
* **Benefit:** Reduces the number of `@memcpy` calls from 370 down to less than 20. This dramatically reduces call overhead and improves CPU L1/L2 cache prefetching efficiency.
* **Implementation Plan:**
  1. Implement a sorting and merging algorithm inside `src/dll/rollback.zig` (triggered during `StatePool.allocate`).
  2. Keep the raw region configuration in `rollback_regions.zig` as-is for readability, but run the coalescing step at runtime.

### Strategy B: SIMD Vectorization (AVX2/SSE4.2 in 32-bit mode)
* **Concept:** Instruct the compiler to target modern x86 CPU features (such as AVX2 and SSE4.2) during the 32-bit compilation, allowing the compiler to use 128-bit (XMM) and 256-bit (YMM) vector registers for memory copies.
* **Benefit:** A single `vmovdqu` instruction can copy 32 bytes of memory at once, compared to only 4 bytes in standard 32-bit x86 mode.
* **Implementation Plan:** Modify the build flags in `build.zig` to append target features when building in Release mode.

### Strategy C: Enhanced REP MOVSB (ERMS)
* **Concept:** Modern CPUs (Intel Haswell+, AMD Zen+) have specialized hardware microcode that optimizes the assembly `REP MOVSB` instruction for blocks larger than 128 bytes.
* **Benefit:** The CPU handles memory copies directly using internal wide buses at hardware speed, bypassing registers.
* **Implementation Plan:** When regions are coalesced (resulting in large contiguous chunks), the compiler will naturally compile `@memcpy` into optimized `rep movsb` instructions.

---

## 2. Physics Simulation Rerun Optimizations

During a rollback, the game engine must fast-forward and re-simulate up to 8 frames in a single 16.6ms frame tick.

### Strategy A: Headless Simulation (Graphics Short-Circuiting)
* **Concept:** During rerun frames (`isRerunning() == true`), the game executes physics, but also executes animation ticks, particle spawning, and visual effects whose outputs are immediately discarded since they aren't rendered.
* **Benefit:** Bypassing graphical update functions during reruns reduces the CPU time required for each fast-forward frame by up to 50%.
* **Implementation Plan:**
  1. Research MBAA.exe functions responsible for spawning cosmetic particles or updating sprite animations.
  2. Apply inline assembly hooks to return early from those functions if `state.nm.?.isRerunning()` is true.

### Strategy B: Temporary Thread Priority Boosting
* **Concept:** Temporarily elevate the game process's main thread priority during the rollback phase to ensure the Windows thread scheduler does not preempt the game mid-rerun.
* **Benefit:** Prevents micro-stutters and frame drops caused by background processes interrupting the heavy rerun phase.
* **Implementation Plan:**
  1. Call `SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL)` right before calling `loadStateForFrame`.
  2. Restore to `THREAD_PRIORITY_NORMAL` once the rerun completes (inside `finishedRerun`).

---

## 3. Compiler Flag Experiment (32-bit Target Features)

We performed a compilation experiment to verify if targeting modern micro-architectures produces distinct and optimized machine code for the 32-bit binary targets.

### Compilation Commands

1. **Baseline build:**
   ```bash
   zig build -Dtarget=x86-windows-gnu -Dcpu=baseline -Doptimize=ReleaseFast
   ```
2. **Optimized build (Haswell):**
   ```bash
   zig build -Dtarget=x86-windows-gnu -Dcpu=haswell -Doptimize=ReleaseFast
   ```

### Experiment Results

| Binary | Build Profile | Size (Bytes) | SHA-256 Hash |
| :--- | :--- | :--- | :--- |
| **`hook.dll`** | Baseline | 10,763,776 B | `98aab6547b7b054c9c4c85debcca24c186688ba2f8c617ce13faf2fca9641a40` |
| **`hook.dll`** | Optimized (Haswell) | **10,773,504 B** | `b51c1a79da53e0b4905c6f8efa47e6680974a723d171b2d1fdb4b40d4b7e73c2` |
| | | | |
| **`zzcaster.exe`** | Baseline | 12,324,864 B | `4538c7116a1a9ee150bb0ab94d4bc5ab84ea7ea534d9144739f0a5bb869ff076` |
| **`zzcaster.exe`** | Optimized (Haswell) | **12,319,744 B** | `4c83c60ea60b6f6cb70ab4ccdb1c4fa950d8bc412bd616a62466505fc37eae41` |

### Key Observations

* **Vector Code Expansion:** The optimized `hook.dll` is slightly **larger** (by ~9.7 KB). This is a characteristic result of SIMD loop vectorization and loop unrolling, where the compiler generates longer sequences of 256-bit AVX instructions (like `vmovdqu`) to copy 32 bytes per instruction instead of using shorter loop branches.
* **Instruction Set Verification:** The completely different SHA-256 hashes confirm that specifying `-Dcpu=haswell` successfully alters LLVM's code generation, compiling the DLL with hardware-optimized memory copy routines.

---

## 4. Mandatory Pre-Implementation Metrics Requirement

> [!IMPORTANT]
> **Mandatory Rule:** Whoever implements these optimizations is **required** to collect baseline performance metrics **before** writing any implementation code. This ensures we can measure the actual performance delta and avoid placebo optimizations.

### Guidelines for Metric Collection
1. **Target Parameters:**
   * Time spent in the state saving loop (`StatePool.saveState`) in microseconds.
   * Time spent in the state loading loop (`StatePool.loadState`) in microseconds.
   * Total frame processing time during standard frames vs. rollback rerun frames.
2. **Acceptable Data Sources:**
   * If real-world netplay telemetry is not available, the developer **must** use **mockup data** (e.g. running the simulation tests in `src/dll/test_simulation.zig` under a profiler, or writing a micro-benchmark that emulates the memory copying of the 370 regions).
3. **Documentation:**
   * The collected baseline metrics must be documented in the pull request or design log to serve as a benchmark for verifying the optimization's success.


