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

thread_local! {
    /// The pipeline creations on this thread since the last [`take_pipelines`]: their count
    /// and their total nanoseconds.
    static PIPELINES: Cell<(u32, u64)> = const { Cell::new((0, 0)) };
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
    fn millis_saturates() {
        let a = MonoTime::from_nanos(5_000_000);
        let b = MonoTime::from_nanos(12_000_000);
        assert_eq!(millis(a, b), 7);
        assert_eq!(millis(b, a), 0);
    }
}
