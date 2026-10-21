//! Diagnostics of slow execs (ours): the time an exec spends on the host, by phase, and the time
//! pipeline creations take inside it. Only the slow ones are logged, so a cold application launch
//! shows where its seconds go (pipeline compiles, paging, the GPU) without a line per frame.

use std::cell::Cell;
use std::time::Duration;

use crate::platform::os::clock::MonoTime;

/// An exec whose host side took this long, or whose GPU work took this long after the commit,
/// is logged.
pub const SLOW_EXEC: Duration = Duration::from_millis(100);

/// A pipeline creation that took this long is logged on its own.
pub const SLOW_PIPELINE: Duration = Duration::from_millis(50);

/// An object lookup that made the object, a guest delete, or a wait for a task's lock that took
/// this long is logged on its own.
pub const SLOW_CREATION: Duration = Duration::from_millis(20);

thread_local! {
    /// The pipeline creations on this thread since the last [`take_pipelines`]: their count
    /// and their total nanoseconds.
    static PIPELINES: Cell<(u32, u64)> = const { Cell::new((0, 0)) };
    /// The buffers made over guest pages on this thread since the last [`take_page_buffers`]:
    /// their count, and the total nanoseconds of mapping the pages and of making the buffers.
    static PAGE_BUFFERS: Cell<(u32, u64, u64)> = const { Cell::new((0, 0, 0)) };
}

/// Records one buffer made over guest pages on this thread: `map` mapping the pages, `buffer`
/// making the buffer over them.
pub fn add_page_buffer(map: Duration, buffer: Duration) {
    let nanos = |d: Duration| u64::try_from(d.as_nanos()).unwrap_or(u64::MAX);
    PAGE_BUFFERS.with(|p| {
        let (count, mapped, made) = p.get();
        p.set((
            count.saturating_add(1),
            mapped.saturating_add(nanos(map)),
            made.saturating_add(nanos(buffer)),
        ));
    });
}

/// The buffers made over guest pages on this thread since the last call, the total time mapping
/// their pages and making them; the record restarts.
pub fn take_page_buffers() -> (u32, Duration, Duration) {
    let (count, mapped, made) = PAGE_BUFFERS.with(|p| p.replace((0, 0, 0)));
    (
        count,
        Duration::from_nanos(mapped),
        Duration::from_nanos(made),
    )
}

/// Whether the timings are taken at all: only when info lines go somewhere (`REIMS_VGPU_LOG`, or
/// a host's hook), so a release run reads no clock for them.
pub fn enabled() -> bool {
    log::max_level() >= log::LevelFilter::Info
}

/// Records one pipeline creation of `took` on this thread.
pub fn add_pipeline(took: Duration) {
    let nanos = u64::try_from(took.as_nanos()).unwrap_or(u64::MAX);
    PIPELINES.with(|p| {
        let (count, total) = p.get();
        p.set((count.saturating_add(1), total.saturating_add(nanos)));
    });
}

/// The pipeline creations recorded on this thread since the last call, and their total time;
/// the record restarts.
pub fn take_pipelines() -> (u32, Duration) {
    let (count, total) = PIPELINES.with(|p| p.replace((0, 0)));
    (count, Duration::from_nanos(total))
}

/// One phase of every exec, summed across tasks for the once-a-second summary line.
pub enum ExecPhase {
    /// Waiting for and doing the preparation (lookups, paging).
    Prepare,
    /// Decoding the command buffers.
    Decode,
    /// From the decode to the GPU's completion.
    Gpu,
}

struct PhaseStats {
    total: std::sync::atomic::AtomicU64,
    max: std::sync::atomic::AtomicU64,
}

impl PhaseStats {
    const fn new() -> Self {
        Self {
            total: std::sync::atomic::AtomicU64::new(0),
            max: std::sync::atomic::AtomicU64::new(0),
        }
    }

    fn add(&self, nanos: u64) {
        use std::sync::atomic::Ordering;
        self.total.fetch_add(nanos, Ordering::Relaxed);
        self.max.fetch_max(nanos, Ordering::Relaxed);
    }

    /// The average over `count` and the max, in tenths of a millisecond; the record restarts.
    fn take(&self, count: u64) -> (u64, u64) {
        use std::sync::atomic::Ordering;
        let total = self.total.swap(0, Ordering::Relaxed);
        let max = self.max.swap(0, Ordering::Relaxed);
        (
            total
                .checked_div(count)
                .unwrap_or(0)
                .checked_div(100_000)
                .unwrap_or(0),
            max.checked_div(100_000).unwrap_or(0),
        )
    }
}

static EXEC_COUNT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static EXEC_PHASES: [PhaseStats; 3] = [PhaseStats::new(), PhaseStats::new(), PhaseStats::new()];
static EXEC_REPORTED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// One task's execs since the last summary.
#[derive(Default)]
struct TaskExecs {
    count: u64,
    /// Execs that began with none of the task's earlier execs still on the GPU.
    idle: u64,
    /// Summed time from the task's last completion to such an exec's start, in nanoseconds.
    idle_gap: u64,
    /// Summed time from decode to GPU done, in nanoseconds.
    gpu: u64,
    /// Live: the task's execs not yet completed.
    in_flight: u64,
    /// Live: when the task's last exec completed, in nanoseconds.
    last_done: u64,
}

static EXEC_TASKS: crate::sync::Mutex<std::collections::BTreeMap<u32, TaskExecs>> =
    crate::sync::Mutex::new(std::collections::BTreeMap::new());

/// Counts one exec of task `task`, begun at `started`, toward the next summary's busiest tasks.
pub fn count_exec_task(task: u32, started: MonoTime) {
    let started = started.as_nanos();
    let mut tasks = EXEC_TASKS.lock();
    let t = tasks.entry(task).or_default();
    t.count = t.count.saturating_add(1);
    if t.in_flight == 0 {
        t.idle = t.idle.saturating_add(1);
        if t.last_done != 0 {
            t.idle_gap = t
                .idle_gap
                .saturating_add(started.saturating_sub(t.last_done));
        }
    }
    t.in_flight = t.in_flight.saturating_add(1);
}

/// An exec of task `task` completed at `done`, `gpu` after its decode.
pub fn exec_task_done(task: u32, done: MonoTime, gpu: Duration) {
    let mut tasks = EXEC_TASKS.lock();
    let t = tasks.entry(task).or_default();
    t.in_flight = t.in_flight.saturating_sub(1);
    t.last_done = t.last_done.max(done.as_nanos());
    t.gpu = t
        .gpu
        .saturating_add(u64::try_from(gpu.as_nanos()).unwrap_or(u64::MAX));
}

/// The busiest tasks since the last call, as "task:count (idle starts, their average gap after
/// the task's last completion, average decode to GPU done)"; the counts restart.
fn take_exec_tasks() -> String {
    let mut tasks = EXEC_TASKS.lock();
    let mut out: Vec<(u32, u64, String)> = Vec::new();
    for (&task, t) in tasks.iter_mut() {
        if t.count == 0 {
            continue;
        }
        let micros = |total: u64, n: u64| {
            total
                .checked_div(n)
                .unwrap_or(0)
                .checked_div(1000)
                .unwrap_or(0)
        };
        out.push((
            task,
            t.count,
            format!(
                "{task}:{} (idle {} gap {} us, gpu {} us)",
                t.count,
                t.idle,
                micros(t.idle_gap, t.idle),
                micros(t.gpu, t.count)
            ),
        ));
        t.count = 0;
        t.idle = 0;
        t.idle_gap = 0;
        t.gpu = 0;
    }
    drop(tasks);
    out.sort_unstable_by_key(|a| std::cmp::Reverse(a.1));
    out.into_iter()
        .take(4)
        .map(|(_, _, line)| line)
        .collect::<Vec<_>>()
        .join(", ")
}

/// Records one phase of an exec. [`ExecPhase::Gpu`] counts the exec; it comes last.
pub fn add_exec_phase(phase: ExecPhase, took: Duration) {
    let nanos = u64::try_from(took.as_nanos()).unwrap_or(u64::MAX);
    let stats = match phase {
        ExecPhase::Prepare => &EXEC_PHASES[0],
        ExecPhase::Decode => &EXEC_PHASES[1],
        ExecPhase::Gpu => {
            EXEC_COUNT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            &EXEC_PHASES[2]
        }
    };
    stats.add(nanos);
}

/// Logs the exec summary when a second has passed since the last one, at `now`.
pub fn report_execs(now: MonoTime) {
    use std::sync::atomic::Ordering;
    let now = now.as_nanos();
    let last = EXEC_REPORTED.load(Ordering::Relaxed);
    if now.saturating_sub(last) < 1_000_000_000
        || EXEC_REPORTED
            .compare_exchange(last, now, Ordering::Relaxed, Ordering::Relaxed)
            .is_err()
    {
        return;
    }
    let count = EXEC_COUNT.swap(0, Ordering::Relaxed);
    let [prepare, decode, gpu] = &EXEC_PHASES;
    let (p, pm) = prepare.take(count);
    let (d, dm) = decode.take(count);
    let (g, gm) = gpu.take(count);
    let tenths = |t: u64| format!("{}.{}", t.checked_div(10).unwrap_or(0), t.wrapping_rem(10));
    log::info!(
        "reims-vgpu timing: execs: {count} in {} ms; prepare avg {} max {} ms, decode avg {} max \
         {} ms, decode to GPU done avg {} max {} ms; by task {}",
        now.saturating_sub(last).checked_div(1_000_000).unwrap_or(0),
        tenths(p),
        tenths(pm),
        tenths(d),
        tenths(dm),
        tenths(g),
        tenths(gm),
        take_exec_tasks()
    );
}

/// Milliseconds between two points, for the lines.
pub fn millis(from: MonoTime, to: MonoTime) -> u128 {
    to.saturating_duration_since(from).as_millis()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pipelines_add_up_and_restart() {
        let _ = take_pipelines();
        add_pipeline(Duration::from_millis(30));
        add_pipeline(Duration::from_millis(45));
        assert_eq!(take_pipelines(), (2, Duration::from_millis(75)));
        assert_eq!(take_pipelines(), (0, Duration::ZERO));
    }

    #[test]
    fn pipelines_are_per_thread() {
        let _ = take_pipelines();
        add_pipeline(Duration::from_millis(10));
        let other = std::thread::scope(|s| s.spawn(take_pipelines).join().unwrap());
        assert_eq!(other, (0, Duration::ZERO));
        assert_eq!(take_pipelines(), (1, Duration::from_millis(10)));
    }

    #[test]
    fn page_buffers_add_up_and_restart() {
        let _ = take_page_buffers();
        add_page_buffer(Duration::from_millis(3), Duration::from_millis(5));
        add_page_buffer(Duration::from_millis(4), Duration::from_millis(1));
        assert_eq!(
            take_page_buffers(),
            (2, Duration::from_millis(7), Duration::from_millis(6))
        );
        assert_eq!(take_page_buffers(), (0, Duration::ZERO, Duration::ZERO));
    }

    #[test]
    fn millis_saturates() {
        let a = MonoTime::from_nanos(5_000_000);
        let b = MonoTime::from_nanos(12_000_000);
        assert_eq!(millis(a, b), 7);
        assert_eq!(millis(b, a), 0);
    }
}
