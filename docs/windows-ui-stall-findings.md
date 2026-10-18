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

