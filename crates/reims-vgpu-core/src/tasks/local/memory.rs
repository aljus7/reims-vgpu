//! Task memory: the bounds checks, the host mappings of both setups, the no-copy buffers over
//! task memory, and the copies and cursors guest commands read through.

use std::sync::Arc;

use super::{
    Backend, LocalTask, PAGE, PAGE_MASK, RaiseKind, page_address, raise_carrying, raise_caught,
    raise_on,
};
use crate::device::tasks::MAX_LOCAL_TASK_LENGTH;
use crate::host::{HostPtr, PhysRange};
use crate::memory::cursor::Cursor;
use crate::memory::map::GuestRun;
use crate::memory::mapping::{Mapping, Teardown};
use crate::memory::tracker::RangeTracker;
use crate::num::{ToU64, ToUsize};
use crate::platform::Platform;
use crate::platform::device::GpuDevice;
use crate::platform::os::clock::Clock;
use crate::raise::{Kept, keep_forever};
use crate::raise::{OnFault, RaiseResult};
use crate::resources::host::MappedAddress;
use crate::rt::Hold;
use crate::tasks::{Completion, ExecStatus};

/// Whether paging gathers guest pages through the memory map's buffers over guest RAM: on unless
/// `REIMS_VGPU_GATHER` is `0`, read once.
fn gathers_enabled() -> bool {
    static ENABLED: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ENABLED.get_or_init(|| std::env::var_os("REIMS_VGPU_GATHER").is_none_or(|v| v != "0"))
}

/// Whether physically contiguous task pages are mapped straight over guest RAM: on unless
/// `REIMS_VGPU_DIRECT` is `0`, read once.
fn direct_enabled() -> bool {
    static ENABLED: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ENABLED.get_or_init(|| std::env::var_os("REIMS_VGPU_DIRECT").is_none_or(|v| v != "0"))
}

/// The first guest physical address of `ranges` where they are one contiguous run of `length`
/// bytes in all.
fn contiguous(ranges: &[PhysRange], length: u64) -> Option<u64> {
    let start = ranges.first()?.physical_address;
    let mut end = start;
    for range in ranges {
        if range.physical_address != end {
            return None;
        }
        end = end.checked_add(range.physical_length)?;
    }
    (end.wrapping_sub(start) == length).then_some(start)
}

/// Counts mappings of task pages taken straight from guest RAM against those remapped, and
/// logs the totals every 4096 with timing on.
fn count_direct(direct: bool) {
    use std::sync::atomic::{AtomicU64, Ordering};
    static DIRECT: AtomicU64 = AtomicU64::new(0);
    static MAPPED: AtomicU64 = AtomicU64::new(0);
    let counter = if direct { &DIRECT } else { &MAPPED };
    counter.fetch_add(1, Ordering::Relaxed);
    let (d, m) = (
        DIRECT.load(Ordering::Relaxed),
        MAPPED.load(Ordering::Relaxed),
    );
    if crate::timing::enabled() && d.wrapping_add(m) & 4095 == 0 {
        log::info!(
            "reims-vgpu timing: task page mappings: {d} straight over guest RAM, {m} remapped"
        );
    }
}

/// The bounds check every task accessor opens with. A range ending exactly at the task's end is
/// accepted (a copy's is not: [`LocalTask::copy_range`]).
pub(super) fn check_task_range(offset: u64, length: u64, task_length: u64) -> RaiseResult<()> {
    let (end, overflow) = offset.overflowing_add(length);
    if overflow || end > task_length {
        return raise_caught(
            RaiseKind::Range,
            format_args!(
                "{length:#x} bytes at task offset {offset:#x} run past the task's {task_length:#x}"
            ),
        );
    }
    Ok(())
}

/// The checks both setups make before mapping `offset..offset + length` page by page, in order:
/// the range, a page table, the offset's and the length's alignment, a length.
fn check_mappable(offset: u64, length: u64, task_length: u64, has_root: bool) -> RaiseResult<()> {
    check_task_range(offset, length, task_length)?;
    if !has_root {
        return raise_caught(
            RaiseKind::NoPageTable,
            "no page table to map task memory through",
        );
    }
    if offset & PAGE_MASK != 0 {
        return raise_caught(
            RaiseKind::UnalignedOffset,
            format_args!("task offset {offset:#x} to map is not page-aligned"),
        );
    }
    if length & PAGE_MASK != 0 {
        return raise_caught(
            RaiseKind::UnalignedLength,
            format_args!("length {length:#x} to map is not page-aligned"),
        );
    }
    if length == 0 {
        return raise_caught(
            RaiseKind::ZeroLength,
            format_args!("map of 0 bytes at task offset {offset:#x}"),
        );
    }
    Ok(())
}

impl<P: Platform> LocalTask<P> {
    /// The guest's map command. In the blocks setup it maps the range into the host's task
    /// under the task's shared lock, before the completion; in the map setup it only completes.
    pub(super) fn map_memory(
        &self,
        hold: Hold<'_>,
        offset: u64,
        length: u64,
        done: Completion,
    ) -> RaiseResult<()> {
        // With a memory map this succeeds without any check.
        if let Backend::Blocks { mapped } = &self.backend {
            let _lock = self.base.mutex.read();
            self.map_into_host(hold, mapped, offset, length)?;
        }
        done(ExecStatus::OK, None);
        Ok(())
    }

    /// Maps `offset..offset + length` (page-aligned) into the host's task, one run of pages at a
    /// time, then adds it to `mapped`. A refused or raising run leaves `mapped` as it was.
    pub(super) fn map_into_host(
        &self,
        hold: Hold<'_>,
        mapped: &RangeTracker,
        offset: u64,
        length: u64,
    ) -> RaiseResult<()> {
        check_mappable(offset, length, self.length, !self.task_root.is_null())?;
        let task = self.task_info.task;
        let device = self.device.upgrade();
        // With the device gone nothing maps
        let map = |start: u64, read_only: bool, range: PhysRange| -> bool {
            device
                .as_ref()
                .is_some_and(|d| d.map_memory_in_task(task, start, read_only, &[range]))
        };
        let mut range = PhysRange::default();
        let mut range_start: u64 = 0;
        let mut writable = false;
        if let Some(walker) = &self.walker {
            walker.visit_pages_in_range(
                hold,
                OnFault::Return,
                offset,
                length,
                &mut |address, page, page_writable| {
                    let physical = page_address(page);
                    // The run grows only from its start page (so at most 2 pages), and the `{0, 0}`
                    // start matches a read-only first leaf at guest page 1.
                    if physical == range.physical_address.wrapping_add(PAGE)
                        && page_writable == u32::from(writable)
                    {
                        range.physical_length = range.physical_length.wrapping_add(PAGE);
                    } else {
                        // The flushed run takes the next page's writability.
                        if range.physical_length != 0
                            && !map(range_start, page_writable == 0, range)
                        {
                            return raise_caught(
                                RaiseKind::HostMap,
                                format_args!("the host did not map task offset {range_start:#x}"),
                            );
                        }
                        range = PhysRange {
                            physical_address: physical,
                            physical_length: PAGE,
                        };
                        range_start = address;
                        writable = page_writable != 0;
                    }
                    Ok(true)
                },
            )?;
        }
        if range.physical_length != 0 && !map(range_start, !writable, range) {
            return raise_caught(
                RaiseKind::HostMap,
                format_args!("the host did not map task offset {range_start:#x}"),
            );
        }
        mapped.add_to_range(offset, length)
    }

    /// The guest's unmap command, under the task's unique lock: the range check (every setup),
    /// the object list's unmap where the range overlaps it, then in the blocks setup the
    /// tracker (which refuses a zero or unaligned range) and the host, before the completion.
    pub(super) fn unmap_memory(
        &self,
        offset: u64,
        length: u64,
        done: Completion,
    ) -> RaiseResult<()> {
        let _lock = self.base.mutex.write();
        check_task_range(offset, length, self.length)?;
        let end = offset.wrapping_add(length);
        let (_, _, lists) = self.parts();
        let (list_offset, list_length) = *self.object_list_range.lock();
        let list_end = list_offset.wrapping_add(u64::from(list_length));
        if offset < list_end && list_offset < end {
            lists.unmap_object_list();
        }
        // The placement list of a local task is empty: `0..0` overlaps nothing
        if let Backend::Blocks { mapped } = &self.backend {
            mapped.remove_from_range(offset, length)?;
            // With the device gone the host refuses
            let unmapped = self
                .device
                .upgrade()
                .is_some_and(|d| d.unmap_memory_in_task(self.task_info.task, offset, length));
            if !unmapped {
                return raise_caught(
                    RaiseKind::HostUnmap,
                    format_args!(
                        "the host did not unmap {length:#x} bytes at task offset {offset:#x}"
                    ),
                );
            }
        }
        done(ExecStatus::OK, None);
        Ok(())
    }

    /// A mapping of the task's pages `offset..offset + length` from the device's memory map, one
    /// physical range per run of pages, read-only if any page is. `None` without a memory map,
    /// where the map refuses the ranges, or where `need_writable` meets a read-only page.
    pub(super) fn virtual_mapping(
        &self,
        hold: Hold<'_>,
        offset: u64,
        length: u64,
        need_writable: bool,
    ) -> RaiseResult<Option<Arc<Mapping<P>>>> {
        let (ranges, writable) = self.physical_runs(hold, offset, length)?;
        if need_writable && !writable {
            return Ok(None);
        }
        let memory_map = self.device.upgrade().and_then(|d| d.memory_map());
        if let Some(m) = &memory_map
            && gathers_enabled()
            && direct_enabled()
        {
            let straight = writable
                .then(|| contiguous(&ranges, length))
                .flatten()
                .and_then(|start| m.host_address_within_range(start, length));
            count_direct(straight.is_some());
            if let Some(host) = straight {
                // Guest RAM stays mapped for the device's life: nothing to tear down.
                return Ok(Some(Mapping::new(host, length, true, Teardown::None)));
            }
        }
        Ok(memory_map.and_then(|m| m.new_range_mapping(&ranges, length, u32::from(!writable))))
    }

    /// The guest physical runs of the task's pages `offset..offset + length`, in order, and
    /// whether every page is writable, after the mapping checks.
    fn physical_runs(
        &self,
        hold: Hold<'_>,
        offset: u64,
        length: u64,
    ) -> RaiseResult<(Vec<PhysRange>, bool)> {
        check_mappable(offset, length, self.length, !self.task_root.is_null())?;
        let mut ranges: Vec<PhysRange> = Vec::new();
        let mut writable = true;
        let mut range = PhysRange::default();
        if let Some(walker) = &self.walker {
            walker.visit_pages_in_range(
                hold,
                OnFault::Return,
                offset,
                length,
                &mut |_address, page, page_writable| {
                    let physical = page_address(page);
                    // One read-only leaf makes the whole mapping read-only.
                    if page_writable == 0 {
                        writable = false;
                    }
                    // Runs are cut at 2 pages; a first leaf at guest page 1 extends the empty run into
                    // one at physical 0.
                    if physical == range.physical_address.wrapping_add(PAGE) {
                        range.physical_length = range.physical_length.wrapping_add(PAGE);
                    } else {
                        if range.physical_length != 0 {
                            ranges.push(range);
                        }
                        range = PhysRange {
                            physical_address: physical,
                            physical_length: PAGE,
                        };
                    }
                    Ok(true)
                },
            )?;
        }
        if range.physical_length != 0 {
            ranges.push(range);
        }
        Ok((ranges, writable))
    }

    /// The task's pages from `page`, `length` bytes, as runs in the memory map's gather buffers
    /// ([`crate::memory::map::MemoryMap::guest_chunk`]), cut where a run leaves a chunk. `None`
    /// in the blocks setup, with gathers turned off (`REIMS_VGPU_GATHER=0`), with no device or
    /// memory map, for a read-only page (a download would write it), or where a chunk has no
    /// buffer: the caller maps the pages instead.
    pub(super) fn guest_runs(
        &self,
        hold: Hold<'_>,
        page: u32,
        length: u64,
    ) -> RaiseResult<Option<Arc<[GuestRun<P>]>>> {
        if !gathers_enabled() || matches!(self.backend, Backend::Blocks { .. }) {
            return Ok(None);
        }
        let Some(device) = self.base.mtl_device.as_deref() else {
            return Ok(None);
        };
        let Some(memory_map) = self.device.upgrade().and_then(|d| d.memory_map()) else {
            return Ok(None);
        };
        let timed = crate::timing::enabled();
        let clock = self.platform.clock();
        let now = || timed.then(|| clock.now_mono());
        let started = now();
        let (ranges, writable) = self.physical_runs(hold, page_address(page), length)?;
        let walked = now();
        if !writable {
            return Ok(None);
        }
        let mut runs = Vec::with_capacity(ranges.len());
        let mut at: u64 = 0;
        for range in ranges {
            let mut physical = range.physical_address;
            let mut left = range.physical_length;
            while left != 0 {
                let Some((buffer, offset, in_chunk)) = memory_map.guest_chunk(device, physical)?
                else {
                    return Ok(None);
                };
                let piece = left.min(in_chunk);
                runs.push(GuestRun {
                    buffer,
                    offset,
                    at,
                    length: piece,
                });
                at = at.wrapping_add(piece);
                physical = physical.wrapping_add(piece);
                left = left.wrapping_sub(piece);
            }
        }
        if at != length {
            return Ok(None);
        }
        if let (Some(started), Some(walked), Some(made)) = (started, walked, now()) {
            crate::timing::add_page_buffer(
                walked.saturating_duration_since(started),
                made.saturating_duration_since(walked),
            );
        }
        Ok(Some(runs.into()))
    }

    /// The host address of task memory at `offset`, mapped for `length` bytes. In the map setup
    /// the covering pages get a fresh mapping, which comes back with the address (the caller
    /// holds it while it uses the address); a writability check that then raises carries it
    /// on with the raise, so it is unmapped where the raise ends, after the handler.
    /// In the blocks setup the range is mapped into the host's task first if the tracker says
    /// it is not; the host's mapping is not checked for writability (a read-only leaf is written
    /// through).
    pub(super) fn mapped_address(
        &self,
        hold: Hold<'_>,
        offset: u64,
        length: u64,
        need_writable: bool,
    ) -> RaiseResult<MappedAddress<P>> {
        check_task_range(offset, length, self.length)?;
        let Backend::Blocks { mapped } = &self.backend else {
            let start = offset & !PAGE_MASK;
            let end = offset.wrapping_add(length).wrapping_add(PAGE_MASK) & !PAGE_MASK;
            let Some(mapping) =
                self.virtual_mapping(hold, start, end.wrapping_sub(start), need_writable)?
            else {
                return raise_caught(
                    RaiseKind::Mapping,
                    format_args!("no mapping of {length:#x} bytes at task offset {offset:#x}"),
                );
            };
            if need_writable && !mapping.writable() {
                // The raise carries the mapping: its unmap comes where the raise ends, after
                // the handler's fault.
                return raise_carrying(
                    RaiseKind::ReadOnlyMapping,
                    format_args!("the mapping at task offset {offset:#x} is read-only"),
                    mapping,
                );
            }
            return Ok(MappedAddress {
                address: mapping.virtual_address().wrapping_add(offset & PAGE_MASK),
                mapping: Some(mapping),
            });
        };
        // Once the tracker says mapped, the host keeps the old mapping.
        if !mapped.test_range(offset, length)? {
            mapped.visit_unmapped_ranges(offset, length, &mut |range_offset, range_length| {
                self.map_into_host(hold, mapped, range_offset, range_length)?;
                Ok(true)
            })?;
        }
        Ok(MappedAddress::unmapped(
            self.task_info.base_address.wrapping_add(offset),
        ))
    }

    /// A no-copy buffer over the task's pages from `page`, `length` bytes. In the blocks setup
    /// it wraps the host task's memory, with no deallocator; in the map setup a fresh mapping,
    /// which the buffer's deallocator owns (and which is kept for good when Metal refuses the
    /// buffer: its address space stays taken).
    pub(super) fn buffer_for_page(
        &self,
        hold: Hold<'_>,
        page: u32,
        length: u64,
    ) -> RaiseResult<P::Buffer> {
        let timed = crate::timing::enabled();
        let clock = self.platform.clock();
        let now = || timed.then(|| clock.now_mono());
        let started = now();
        let mapped;
        let device = self.base.mtl_device.as_deref();
        let buffer = if let Backend::Blocks { .. } = self.backend {
            // The blocks setup: the host's task maps it, and no mapping comes back.
            let pointer = self
                .mapped_address(hold, page_address(page), length, false)?
                .address;
            mapped = now();
            if pointer.is_null() {
                return raise_caught(
                    RaiseKind::NullAddress,
                    format_args!("no host address for task page {page:#x}"),
                );
            }
            #[allow(unsafe_code)] // architecture 17.3: the no-copy buffer over host memory
            // SAFETY: `pointer..pointer+length` is the host task's own mapping of the task range
            // (the host's `map_memory` callback's), which the host keeps until the guest unmaps
            // it; Metal gets the same memory with no deallocator.
            let bytes = unsafe { crate::platform::HostRange::new(pointer, length) };
            match device {
                Some(d) => d.new_buffer_over_host_memory(OnFault::Return, bytes, 0, None)?,
                None => None,
            }
        } else {
            let Some(mapping) = self.virtual_mapping(hold, page_address(page), length, false)?
            else {
                return raise_caught(
                    RaiseKind::NullAddress,
                    format_args!("no host address for task page {page:#x}"),
                );
            };
            mapped = now();
            let pointer = mapping.virtual_address();
            let owned = Arc::clone(&mapping);
            let deallocator = Box::new(move || drop(owned));
            #[allow(unsafe_code)] // architecture 17.3: the no-copy buffer over host memory
            // SAFETY: `pointer..pointer+length` is `mapping`'s VM range (`length` is the
            // mapping's own, page-aligned: `virtual_mapping` refused anything else), and the
            // deallocator owns the mapping, so the range stays mapped until Metal runs it.
            let bytes = unsafe { crate::platform::HostRange::new(pointer, length) };
            let buffer = match device {
                Some(d) => {
                    d.new_buffer_over_host_memory(OnFault::Return, bytes, 0, Some(deallocator))
                }
                None => Ok(None),
            };
            match buffer {
                // The deallocator holds the mapping now
                Ok(Some(buffer)) => {
                    drop(mapping);
                    Some(buffer)
                }
                // Refused: the mapping's range stays taken for good
                Ok(None) => {
                    keep_forever(mapping, Kept::AddressSpace);
                    None
                }
                Err(thrown) => {
                    keep_forever(mapping, Kept::AddressSpace);
                    return Err(thrown);
                }
            }
        };
        if let (Some(started), Some(mapped), Some(made)) = (started, mapped, now()) {
            crate::timing::add_page_buffer(
                mapped.saturating_duration_since(started),
                made.saturating_duration_since(mapped),
            );
        }
        match buffer {
            Some(buffer) => Ok(buffer),
            None => raise_caught(
                RaiseKind::Buffer,
                format_args!("Metal made no buffer over task page {page:#x}"),
            ),
        }
    }

    /// The range check of a copy; returns `offset + length`. Its raise is as `on` says: a copy
    /// is reached both under a handler and with none (a display's colour-space read).
    ///
    /// `end >= length` is refused: a copy ending exactly at the task's end fails (testing.md
    /// 7.1).
    fn copy_range(&self, on: OnFault, offset: u64, length: u64) -> RaiseResult<u64> {
        let (end, overflow) = offset.overflowing_add(length);
        if overflow || end >= self.length {
            return raise_on(
                on,
                RaiseKind::CopyRange,
                format_args!(
                    "copy of {length:#x} bytes at task offset {offset:#x} reaches the task's end, \
                     {:#x}",
                    self.length
                ),
            );
        }
        Ok(end)
    }

    /// Reads the task's pages from `offset` to `end` into `dst` through the device, page by
    /// page, after the range check. Its raises are as `on` says.
    fn copy_pages(
        &self,
        hold: Hold<'_>,
        on: OnFault,
        offset: u64,
        end: u64,
        dst: &mut [u8],
    ) -> RaiseResult<()> {
        let page_offset = offset & PAGE_MASK;
        let start = offset & !PAGE_MASK;
        let size = (end.wrapping_add(PAGE_MASK) & !PAGE_MASK).wrapping_sub(start);
        let mut remaining = dst.len().to_u64();
        let mut current: usize = 0;
        let device = self.device.upgrade();
        let Some(walker) = &self.walker else {
            return Ok(());
        };
        walker.visit_pages_in_range(hold, on, start, size, &mut |address, page, _flags| {
            let mut physical = page_address(page);
            let page_end = physical.wrapping_add(PAGE);
            if address == start {
                physical = physical.wrapping_add(page_offset);
            }
            let current_length = page_end.wrapping_sub(physical).min(remaining);
            let to = current.wrapping_add(current_length.to_usize());
            // `current + remaining` is `dst`'s length throughout, so the part is inside it
            let into = dst.get_mut(current..to).unwrap_or_default();
            let read = match &device {
                Some(d) => d.read_from_physical_address(on, physical, into)?,
                None => false,
            };
            // A failed read is silent: the position does not advance, and the next page is read
            // into it.
            if read {
                current = to;
                remaining = remaining.wrapping_sub(current_length);
            }
            // Ignored by the walker
            Ok(read)
        })
    }

    /// Copies task memory at `offset` into `dst`. Its raises are as `on` says.
    pub(super) fn copy(
        &self,
        hold: Hold<'_>,
        on: OnFault,
        offset: u64,
        dst: &mut [u8],
    ) -> RaiseResult<()> {
        let end = self.copy_range(on, offset, dst.len().to_u64())?;
        self.copy_pages(hold, on, offset, end, dst)
    }

    /// A fresh buffer of task memory at `offset`, `length` bytes (the core's reads). Its raises
    /// are as `on` says.
    pub(super) fn data(
        &self,
        hold: Hold<'_>,
        on: OnFault,
        offset: u64,
        length: u64,
    ) -> RaiseResult<Option<Vec<u8>>> {
        self.base
            .data_from_virtual_offset(on, offset, length, |offset, dst| {
                self.copy(hold, on, offset, dst)
            })
    }

    /// A read-only snapshot of task memory at `offset`, copied now; `None` where the copy
    /// refuses or raises (no log), or where the length is past the largest task (32 GiB, a log),
    /// as it was where the host could not allocate the buffer. The buffer is made only once the
    /// range check passes, so a range the copy refuses touches no memory.
    pub(super) fn cursor(&self, hold: Hold<'_>, offset: u64, length: u64) -> Option<Cursor> {
        if length > MAX_LOCAL_TASK_LENGTH {
            log::warn!(
                "task {}: no cursor of {length:#x} bytes, longer than any task",
                self.task_id
            );
            return None;
        }
        let n = length.to_usize();
        let copied = (|| -> RaiseResult<_> {
            let end = self.copy_range(OnFault::Return, offset, length)?;
            // The buffer starts zeroed, so where a read fails its bytes read 0 (testing.md 7.5).
            let mut buffer = vec![0u8; n];
            self.copy_pages(hold, OnFault::Return, offset, end, &mut buffer)?;
            Ok(buffer)
        })();
        let mut buffer = match copied {
            Ok(buffer) => buffer,
            Err(raised) => {
                hold.land(raised);
                return None;
            }
        };
        let pointer = HostPtr::from_ptr(buffer.as_mut_ptr());
        let keep: Arc<dyn std::any::Any + Send + Sync> = Arc::new(buffer);
        Some(Cursor::with_pointer(keep, pointer, length))
    }
}

#[cfg(test)]
mod contiguity_tests {
    use super::contiguous;
    use crate::host::PhysRange;

    fn pr(physical_address: u64, physical_length: u64) -> PhysRange {
        PhysRange {
            physical_address,
            physical_length,
        }
    }

    #[test]
    fn adjacent_runs_are_one_run_from_the_first() {
        let runs = [pr(0x8000, 0x8000), pr(0x10000, 0x8000), pr(0x18000, 0x4000)];
        assert_eq!(contiguous(&runs, 0x14000), Some(0x8000));
    }

    #[test]
    fn a_gap_a_wrong_total_or_no_runs_is_none() {
        assert_eq!(
            contiguous(&[pr(0x8000, 0x4000), pr(0x10000, 0x4000)], 0x8000),
            None
        );
        assert_eq!(contiguous(&[pr(0x8000, 0x4000)], 0x8000), None);
        assert_eq!(contiguous(&[], 0), None);
    }
}
