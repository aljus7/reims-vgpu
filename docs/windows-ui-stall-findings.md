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
- scripts/windows/guest-perf-tweaks.sh sets METAL_ERROR_MODE=5 (Recovery or running macOS) plus the optional animation tweaks.


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
