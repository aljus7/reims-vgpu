# Windows UI stall findings (Mission Control / Control Center)

Measured with temporary timers on the Windows host:

- GPU work is ~1.3 ms/frame; stalls come from host CPU work in `prepare_resources`.
- Cost is `MemoryMap::new_range_mapping`: guest physical pages are fully fragmented, so each
  4 KiB page becomes one run, and each run costs a placeholder split + `MapViewOfFile3`
  (~14 us). A 8 MiB backing = ~2000 runs = ~30 ms; 64 MB = ~300 ms. Freeing is the same per view.
- Skipping redundant `VirtualProtect` in `protect_max` saved only ~12%.
- A real fix must avoid mapping scattered pages as views (e.g. per-page copy into a contiguous
  host buffer with explicit sync, or lazy transfer buffers). Not implemented.
- The guest only exposes 60 Hz modes, so 120 fps is not reachable.

## Batched remaps (perf/page-copy)

Guest pages are fully fragmented, so each 4 KB page was its own remap and each went through replace() (about 6 syscalls). HostVm::remap_shared_overwrite_many lets Windows map a contiguous run of pieces in one placeholder pass (about 2 syscalls per page). A 2040-run mapping dropped from about 29 ms to about 11 ms.

Remaining costs: deallocate per view, ReplacePhysical, per-piece files::record, and the throwaway section in allocate_anywhere.

Five gpu::backing tests in reims-vgpu-vulkan fail on baseline as well.

## Coalesced deallocate

Windows deallocate now unmaps every view of a contiguous run, coalesces the placeholders, and releases the run once. Measured with a temporary per-command timer over a Mission Control and Control Center workload: the slowest host commands fell from 55-230 ms to at most 27 ms (ExecIndirect2 22 ms, ReplacePhysical 27 ms, DeleteIoSurfaceBacking2 and SynchronizeResources about 11 ms). Mission Control animations run at 36-47 guest frames/s (earlier runs: 18-21). The host uses about 0.8 cores during them, so the rest is waiting. What is left is a 220-320 ms gap when an animation starts, with no commands arriving from the guest, so it is guest-side.

## Guest tweaks and login stall

- Dock/NSGlobalDomain animation defaults (expose duration, launchanim, reduce motion) changed Mission Control from avg 9.3 to 9.7 active fps: negligible. The limit is host-side, not guest animation. com.apple.universalaccess cannot be written without TCC.
- A login after killing QEMU shows 'You shut down because of a problem' and then ~100 s of near-zero frames; it recovers. Shut the guest down over SSH (sudo shutdown -h now) instead of killing QEMU.
- One earlier permanent freeze at the login screen was not reproduced.
- scripts/windows/guest-1-recovery-setup.sh (Recovery) and guest-2-macos-optimize.sh (running macOS) set METAL_ERROR_MODE=5; the second also applies the optional animation tweaks.


## Where the time goes (measured)

- Window fps equals guest fps in every stats sample; GPU time is 1.3-2.4 ms/frame. FIFO and the missing present fences are not the limit (the RX 6600 driver lists no swapchain_maintenance1).
- During Mission Control bursts the guest is ~93% idle (WindowServer 3-8% CPU, ControlCenter ~29% briefly). It is waiting, not computing: next lead is what WindowServer waits on (display-link/vsync event or a host reply) between bursts.


## What precedes a frame gap (measured)

Temporary timestamps on command dispatch and on aise_interrupt (removed again) logged every host-idle gap over 60 ms during Mission Control: 301 of 303 gaps started right after the host raised an interrupt, so the host had finished and was waiting for the guest. 23 gaps were 249-252 ms, which looks like a guest-side 250 ms timeout, and 35 were over 1 s. The guest's vGPU driver waits for something after the interrupt that arrives late or is lost. Next step: tag the interrupt kind (stamp vs display) and see which one the guest waits for.


## Who is waiting: the guest (measured)

Temporary env-gated timestamps (removed) on doorbell writes (0x1020), stamp-interrupt raises, guest acknowledgements (reads of 0x1018) and command dispatch, over 4 Mission Control cycles on the desktop (398 host-idle gaps over 60 ms):

- 126 s of the 153 s of idle time (82%) were between the guest's acknowledgement of a stamp interrupt and its next doorbell: the host had finished and the guest had not yet submitted more. 27 such gaps lasted over 1 s (worst 4.8 s) and 45 were 245-255 ms, which looks like a guest-side 250 ms timeout.
- No display interrupt took part in any gap.
- The guest disk is not the cause: 4 KiB random reads take 0.23 ms, sequential reads 342 MB/s. Guest sleep timers are accurate.
- The guest is ~93% idle during this, so it waits on something other than CPU or disk between the ack and the next submission (a WindowServer/driver wait). Finding what needs guest-side tracing (sample/dtrace needs root, which the guest does not give over SSH without a password).


## Guest samples during Mission Control (measured)

10 s `sample` of WindowServer and Dock while animating (as root over SSH):

- WindowServer main thread: 91% of samples idle in `mach_msg` (waiting for work), ~7.5% in the display timer pass compositing (`CompositorMetal` -> `CA::OGL::render`). The Core Animation render-server thread is 98% in `mach_msg`.
- Texture releases (`MTLIOAccelTexture dealloc` -> `IOConnectCallMethod`) block a WindowServer worker for ~1% of samples; `setPurgeableState` calls for ~0.5%.
- Dock: every thread idle (`__workq_kernreturn`, `mach_msg`, `psynch_cvwait`); no CPU work.

So neither the compositor nor the client computes or blocks on the vGPU for long. The 250 ms to multi-second gaps between a stamp acknowledgement and the next doorbell are a wait for an event nobody is producing (likely a display-link / vsync-style tick or a frame-completion notification the guest expects from the device). Next lead: check which display events the device sends (`new_frame` callback, display interrupt bit, present-complete) against what the guest's `AppleParavirtGPU` driver waits for.


## Cold app launch: Weather (measured)

Launching Weather, which was not open before, with a 12 s `sample` of it: the guest frame rate swings between 0 and 38/s with 1.4-4 s idle gaps. Weather's main thread spends ~15% of samples in `CAEmitterLayer` commits that decode HEIF particle images in software (`HEIFReadPlugin` -> `CA::Render::copy_image`), plus vImage ARGB conversions; the rest is idle in the run loop. So slow first-time assets are guest CPU work on the vCPUs (no hardware image decode in the VM), not vGPU commands or disk: with the work available the pipeline reaches 26-38 frames/s.

### Cold launch: Apple TV / App Store

Sampling Apple TV (10 s) found its main thread 100% blocked in a synchronous XPC call: `ACAccountStore saveVerifiedAccount` (AppleMediaServices) waiting for `accountsd`. It is not GPU, host or CPU work. These apps wait on account/network services (no signed-in Apple ID in the VM), which is the likely cause of their multi-second hangs. Frames during the launch: bursts of 15-30/s between 1-5 s idle gaps.

### Cold launch: Chess (3D, no iCloud)

Chess launch: 0-18 frames/s with 1-6 s gaps, GPU 1.1-3.5 ms per frame. A 10 s sample of Chess shows the main thread mostly waiting, but the busy samples are in `libGLProgrammability` (`glvmSamplerSample`, `glvmInterpretFPTransformFour`), which is Apple's CPU software OpenGL shader interpreter. The legacy OpenGL path falls back to software rendering in this guest (no GL driver on the vGPU), so GL-based apps pay per-pixel guest-CPU cost; Metal paths use the host GPU.

### vsynctester.com in Safari

Steady state: 45-59 frames/s (max gap 20-60 ms, GPU 2-3.4 ms/frame), so the vGPU path sustains near-60 fps for a single animating surface. Frame rate collapses to 2-21/s with 0.5-1.5 s gaps only when the window set changes (maximise, app launch), as in the other cold-start cases. The Safari GPU-process sample shows CPU rasterisation in QuartzCore (`CA::OGL::Shape::FillRenderer::render_lines`, `CA::ScanConverter`): shape fills run through Core Animation's software scan converter on the guest CPU.

### Shader compilation vs. icon cache (Freeform cold launch)

Guest exposes AVX2 and 8 vCPUs. During a cold Freeform launch, `MTLCompilerService` stayed ~0% CPU; the CPU went to the app itself (~98% briefly) and `iconservicesagent` (37-78% for ~10 s). So guest shader compilation is not the culprit; first-run icon rendering/caching is. This matches System Settings icons loading slowly once and then fast.

### Why iconservicesagent is slow

Sampled the user `iconservicesagent` while 5 apps launched cold. The busy threads are in `ISGenerationRequest generateImageReturningRecordIdentifiers` -> `ISIconStackAssetCatalogResource layerDataForSize` -> IconRendering, which renders the layered Tahoe icons in software: `CGImageIsInside_sRGB` colour-gamut scans of FP16 images, vImage conversions, `RGBAf16_mark_inner` blits and `lzfse` compression of the cached result. Everything is CPU image work in the guest; no GPU, disk or vGPU wait. It runs once per icon and size, then the cache is hit, which is why System Settings was slow only the first time.

### vsynctester x3 + Control Center / Wi-Fi click

With three vsynctester tabs, the first scripted click on Control Center/Wi-Fi coincided with 0-4 frames/s for ~13 s (this overlapped page load, so it is not a clean measurement). A second run with everything loaded held a steady ~20-31 frames/s (gaps 55-80 ms, 10 fps at the first click) while clicking Control Center and Wi-Fi; no multi-second stall reproduced. A 10 s WindowServer sample in that window was ~100% idle waits (`mach_msg`, `workq`, `semaphore_timedwait`) with only a little `CA::Render::Updater::prepare_layer0`. The scripted click coordinates are approximate, so the popover may not have opened; the user's observed drop is not reproduced.

### Reproduced: single vsynctester + Control Center

With one vsynctester tab loaded: a steady 55-60 frames/s (gap ~19 ms). Opening Control Center and the Wi-Fi view drops it to 18-27 frames/s (gaps 45-115 ms) for as long as the popover is up, and it returns to 54-60/s when closed. No multi-second stall, and GPU time stays ~2 ms, so the cost is the extra compositing of the blurred/translucent popover (CPU-side in QuartzCore), not the vGPU. Reduce Transparency is the likely mitigation and still needs a manual toggle.

### Correction: the Control Center repro was a cold app launch

A WindowServer sample with the popover open is ~100% idle, so compositing the popover is not the bottleneck. `top` during a scripted click showed Tips launching (65% CPU) and `iconservicesagent` at 42%, i.e. my approximate click coordinates launched a cold app, and the 18-27 fps dip is the same first-launch icon/asset CPU work seen elsewhere, competing with Safari's WebKit processes for the 8 vCPUs. The earlier 'blurred popover' explanation is withdrawn; the user's real Control Center click still needs a manual repro.

### Intermittent vsynctester dips (steady state)

Over two 90-110 s runs with a single vsynctester tab and nothing else touched: 60 fps almost all the time (gaps ~18-20 ms), with short dips: one to 10-30 fps for ~2 s (gap up to 260 ms) and several of 41-50 fps (gaps 45-95 ms). Guest per-process CPU (`top`, which itself costs ~24%) showed Safari WebKit ~22%, WindowServer ~19%, kernel_task ~18%; the only coinciding background load seen was a `WeatherWidget` burst (~22%) and WebKit bursts to 25-26%. GPU time stays ~2 ms, no host-side stall appeared. Likely causes: guest background daemons (widgets, mds, icon/asset caches) taking vCPU time, or host scheduling of the QEMU threads; not proven. To isolate: disable widgets / Spotlight in the guest, or log host-side per-thread CPU alongside.

### vCPU speed and guest timer stalls

Same perl loop (30M iterations): guest 2.17 s vs host 1.73 s, so a vCPU runs at ~80% of native speed (WHPX overhead is small for pure compute). A 20 s guest timer test (7595 x 2 ms sleeps, vsynctester running): median overshoot 0.54 ms, p99 1.3 ms, max 12 ms, none over 50 ms. So the guest scheduler/vCPUs do not stall; the 0.25-5 s stalls seen in rendering are not CPU starvation or vCPU descheduling. They happen on the app/WindowServer<->GPU-driver wait path (or in cold-start single-thread work).

### Register/command trace of the stalls (REIMS_REGTRACE, instrumentation reverted)

Traced every register write, the interrupt-register reads and every FIFO command (with the time of commands over 3 ms) for 364 s of Mission Control and desktop animation. Opcodes below are hex (0x37 = ExecIndirect2, 0x25 = DeleteResource, 0x22 = UnmapMemory).

- **Host command time is small.** Commands over 3 ms: 404 ExecIndirect2 (4.5 s total, 4 over 100 ms, max 275 ms), 50 DeleteResource (0.8 s), the rest under 0.3 s. About 6 s of 364 s, so host command execution does not explain the 0.25-5 s stalls.
- **The display interrupt is never raised during animation.** Register 0x5 read 26,824 times and was always 0, as was the fault register 0xb. The device only raises display interrupts for connect, update and disconnect (`state_machine`), and the display doorbell (0x88) only carries cursor show/move and the live-resize latch. So the device gives the guest no vsync or frame-complete signal at all; pacing is guest-internal.
- **Stalls sit in the middle of busy periods.** 161 of 176 gaps over 100 ms started within 500 ms of 20+ register/command events. Typical shape: the guest's ISR reads 0x6/0x5/0xb, then nothing for 2-5 s, then a new command. Nothing the device could answer is outstanding in those gaps.
- **Host CPU contention does show.** Compiling on the host during a vsynctester run gave 38 of 130 s under 40 fps and a 1.8 s gap, so keeping the host quiet (and QEMU threads at a higher priority) matters.

No fix was found: the wait is inside Apple's closed AppleParavirtGPU/WindowServer on the guest side and the device offers no event it could be waiting on. Untested ideas: raise QEMU and vGPU thread priority on the host, and compare against a real Apple paravirt device's interrupt behaviour.

Tried raising the QEMU process priority to High: 4.4 -> 4.0 avg active fps (4 cycles each, with the register trace still on), so no gain. Not a fix.

## WINQ-inspired WHPX experiment (2026-10-19)

Branch: `perf/whpx-timing`, against pinned QEMU
`7100064d13b42bb1be16671fcf18435822b13c3c`. This does not replace the
Reims QEMU fork or update the release ZIP.

Source inspection corrected the earlier README-only suggestions:

- PAT register synchronization and FastHypercallOutput are already implemented
  in our QEMU. They are not missing optimizations.
- WINQ's high-resolution waits are in its Venus renderer, not a generic QEMU
  timer patch. We do not use that renderer. This branch instead exposes a
  separate, optional `timeBeginPeriod(1)` request in the QEMU process, balanced
  at normal exit; it does not implement Venus' sub-millisecond waits.
- `WHvAdviseGpaRange(Pin)` keeps backing memory resident, per Microsoft's API
  documentation. It does not promise large SLAT pages or solve Reims' scattered
  page-remapping cost. PAT synchronization and memory pinning are separate.
- Our MSR exit handler emulates known registers, including topology and
  APIC behavior, and respects the unknown-MSR fault policy. Blanket
  ignore-write/read-zero shortcuts are not ported.
- No Linux/Venus renderer, CPU passthrough or hybrid-topology changes are used.

The candidate adds a configurable exit-loop budget, optional pin/unpin advice
for eligible RAM mappings of at least 256 MiB, and the optional 1 ms timer
request. All are **off by default**. `Start-VM.ps1 -WhpxTweaks` enables the
5 ms budget, pinning and timer request together. Single-step sequences are
excluded from the budget. The cap is checked between exits; it cannot interrupt
an individual long `WHvRunVirtualProcessor` call.

### Matched desktop measurement

Host: Windows build 28120, RX 6600. Guest: macOS 26.7.1, 8 vCPUs, 8 GiB,
1920x1080. Original executable compared with a stripped, no-debug candidate.
Both use the same Reims DLL, guest disk state (via a disposable overlay), and
Safari canvas animation. No build ran during either measured interval.

The HTTP workload was visually checked. All restored Safari windows/tabs were
closed; AppleScript verified one loaded test tab across all browser windows
before and after each sample. Both samples ran for approximately 120 seconds
with the same window size, a 15-second workload warmup, stats enabled, and
QEMU's guest-frame callback trace enabled. These measure guest submissions,
not physical scanout or Safari's JavaScript callback times.

| Metric | Original QEMU | All three tweaks |
| --- | ---: | ---: |
| Frame callbacks | 7041 | 6946 |
| Median interval | 16.994 ms | 16.874 ms |
| p95 interval | 18.986 ms | 18.517 ms |
| p99 interval | 34.995 ms | 50.120 ms |
| Maximum interval | 68.759 ms | 68.470 ms |
| Average QEMU CPU (100% = one core) | 122.94% | 125.59% |

**No demonstrated improvement.** Typical pacing is similar, and the candidate's
p99 was worse in this pair. Neither matched sample reproduced a 250 ms or
multi-second freeze. This short comparison cannot establish a rare-stall fix
or a statistically significant regression, nor isolate the three effects.
Keep the experiments opt-in; do not promote them to release defaults.

Local raw evidence:
`.work\diagnostics\benchmark-20261019-170356-089` (original),
`.work\diagnostics\benchmark-20261019-170904-200` (candidate), and
`.work\diagnostics\whpx-comparison.json`. The candidate executable SHA256 is
`823fd1245c9010e5b8660b4d3ea15fb00cc668d0cb716de5b1e2d743165c7a5a`.

An early original-worktree boot hit AHCI timeouts and was excluded. A candidate
sample with Safari's restored, missing `file:///tmp/` page was also explicitly
discarded, not interpreted as rendering performance. Earlier exploratory
samples are not the matched results above.

### Other checks and preservation

- Three consecutive final hardware smoke-test passes covered default/off/on
  options, WHPX partition creation, run/pause, clean exit and refusal of an
  invalid loop budget.
- The native QEMU reset/xstate and topology/MSR regression checks passed.
- The Windows VM fixture passed 109 assertions, including argument forwarding
  and refusal of combining WHPX tweaks with TCG. An optional inspection of
  existing EFI artifacts fails their pre-existing `SecureBootModel` expectation;
  those firmware files were not changed for this experiment.
- Patch application tests cover fresh application, idempotence, reversal and
  refusal without partial edits on incompatible sources.
- Only the disposable overlay and copied firmware were written during the
  matched tests. The installed source VM disk's full SHA256 was unchanged.
  The initial excluded boot used the existing development VM.
