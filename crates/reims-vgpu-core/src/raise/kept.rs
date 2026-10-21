//! Values kept for good: [`keep_forever`], with the [`Kept`] rule that names what the host or
//! the guest observes because the value's release never comes.
//!
//! A kept value is not invisible. A live texture shifts later resource indices and a live buffer or
//! heap shifts later GPU VAs, which placements write back to the guest; an IOSurface retain keeps
//! a later unmap Busy; a kept guest mapping never gets its unmap. So a value is kept only where
//! one of these rules says the guest or host sees that its release never comes.
//!
//! Each call has a doc comment and a test.

use std::sync::atomic::{AtomicU64, Ordering};

/// What the host or guest observes because a kept value is never released.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kept {
    /// A guest page's unmap never comes: a guest display's page, a mapping a raise left, a ring a
    /// second start replaced.
    UnmapNeverComes,
    /// An IOSurface's use count stays up, so a later unmap of it is Busy.
    SurfaceUseCount,
    /// A Metal object stays live, so later resource indices and GPU VAs, which placements write
    /// back to the guest, are numbered after it.
    MetalNumbering,
    /// The host's releases never come: a display's parts, a local task's host task.
    HostReleasesNeverCome,
    /// A timer keeps firing on what it holds.
    TimerKeepsFiring,
    /// The address space stays taken: a mapping or deallocator Metal refused, an allocation the
    /// guest sized.
    AddressSpace,
    /// A reader may still use a mapping that was replaced.
    StaleReader,
}

impl Kept {
    /// Every rule, in [`kept_counts`]'s order.
    pub const ALL: [Kept; 7] = [
        Kept::UnmapNeverComes,
        Kept::SurfaceUseCount,
        Kept::MetalNumbering,
        Kept::HostReleasesNeverCome,
        Kept::TimerKeepsFiring,
        Kept::AddressSpace,
        Kept::StaleReader,
    ];

    /// The rule's place in [`Kept::ALL`].
    const fn index(self) -> usize {
        match self {
            Kept::UnmapNeverComes => 0,
            Kept::SurfaceUseCount => 1,
            Kept::MetalNumbering => 2,
            Kept::HostReleasesNeverCome => 3,
            Kept::TimerKeepsFiring => 4,
            Kept::AddressSpace => 5,
            Kept::StaleReader => 6,
        }
    }
}

/// The values kept so far under each rule, in [`Kept::ALL`]'s order: diagnostics only.
static KEPT: [AtomicU64; 7] = [const { AtomicU64::new(0) }; 7];

/// How many values were kept so far under each rule of [`Kept::ALL`], so a debug log can tell
/// whether kept values pile up over a session.
pub fn kept_counts() -> [u64; 7] {
    KEPT.each_ref().map(|n| n.load(Ordering::Relaxed))
}

/// Keeps `v` for good under `rule`: its drop never runs.
pub fn keep_forever<T>(v: T, rule: Kept) {
    if let Some(n) = KEPT.get(rule.index()) {
        n.fetch_add(1, Ordering::Relaxed);
    }
    std::mem::forget(v);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    /// A kept value is never dropped
    #[test]
    fn keep_forever_runs_no_drop() {
        let a = Arc::new(());
        keep_forever(Arc::clone(&a), Kept::MetalNumbering);
        assert_eq!(Arc::strong_count(&a), 2);
    }

    /// Each kept value counts under its own rule.
    #[test]
    fn keep_forever_counts_by_rule() {
        let before = kept_counts();
        keep_forever((), Kept::StaleReader);
        let after = kept_counts();
        let i = Kept::StaleReader.index();
        assert!(after.get(i) > before.get(i));
        assert_eq!(Kept::ALL.get(i), Some(&Kept::StaleReader));
    }
}
