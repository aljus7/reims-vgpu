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
