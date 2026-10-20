//! Objects the guest deleted, kept a short while for an exec that still names them.
//!
//! The guest frees an object (opcodes 37 and 40) once its own command buffers no longer need it,
//! and it empties the object's entry. An exec that reaches the host after that delete, still
//! naming the reference, would find the entry empty and fault the whole exec, which resets the
//! guest's GPU. The delete therefore moves the cached object here instead of releasing it, and a
//! lookup of an empty entry takes it back.
//!
//! Only an empty entry recalls: a reused reference has a live entry again and makes its new
//! object. Resources hold memory, so few are kept, and briefly; the other kinds are small. A
//! delete is remembered (without its object) for longer, so an empty entry can say whether the
//! host saw the reference deleted.

use std::any::{Any, TypeId};
use std::collections::VecDeque;
use std::time::Duration;

use crate::platform::os::MonoTime;

/// The resources kept with their objects, newest first.
pub const KEPT_RESOURCES: usize = 32;
/// How long a resource is kept with its object.
pub const RESOURCE_KEPT_FOR: Duration = Duration::from_secs(3);
/// The objects of the other kinds kept, newest first.
pub const KEPT_OTHERS: usize = 256;
/// How long an object of another kind is kept.
pub const OTHER_KEPT_FOR: Duration = Duration::from_secs(60);
/// The deletes remembered, with or without their objects.
pub const REMEMBERED: usize = 4096;

/// An object released from here, for the caller to drop outside the leaf lock.
pub type Released = Box<dyn Any + Send>;

struct Entry {
    kind: TypeId,
    reference: u32,
    at: MonoTime,
    resource: bool,
    recalled: bool,
    object: Option<Released>,
}

/// What a lookup of an empty entry learns of the reference.
pub enum Recall<T> {
    /// The deleted object, still kept.
    Kept {
        /// Another handle to it.
        object: T,
        /// How long ago it was deleted.
        age: Duration,
        /// Whether this is its first recall.
        first: bool,
    },
    /// Deleted `age` ago, its object since released.
    Released {
        /// How long ago it was deleted.
        age: Duration,
    },
    /// No delete of the reference remembered.
    Unknown,
}

/// The deleted objects, oldest first.
#[derive(Default)]
pub struct Retired {
    entries: VecDeque<Entry>,
}

impl Retired {
    /// Records the delete of `reference` of `kind` at `now`, keeping `object` if there is one.
    /// An earlier delete of the same reference and kind is replaced.
    pub fn retire<T: Send + 'static>(
        &mut self,
        kind: TypeId,
        reference: u32,
        object: Option<T>,
        resource: bool,
        now: MonoTime,
    ) -> Vec<Released> {
        let mut released = Vec::new();
        if let Some(i) = self.position(kind, reference)
            && let Some(old) = self.entries.remove(i)
        {
            released.extend(old.object);
        }
        self.entries.push_back(Entry {
            kind,
            reference,
            at: now,
            resource,
            recalled: false,
            object: object.map(|o| -> Released { Box::new(o) }),
        });
        self.prune(now, &mut released);
        released
    }

    /// What is known of `reference` of `kind` at `now`; a kept object comes back through
    /// `retain` and stays kept.
    pub fn recall<T: 'static>(
        &mut self,
        kind: TypeId,
        reference: u32,
        now: MonoTime,
        retain: impl FnOnce(&T) -> T,
    ) -> (Recall<T>, Vec<Released>) {
        let mut released = Vec::new();
        self.prune(now, &mut released);
        let recall = match self.position(kind, reference) {
            None => Recall::Unknown,
            Some(i) => match self.entries.get_mut(i) {
                None => Recall::Unknown,
                Some(entry) => {
                    let age = now.saturating_duration_since(entry.at);
                    match entry.object.as_ref().and_then(|o| o.downcast_ref::<T>()) {
                        Some(object) => {
                            let first = !entry.recalled;
                            entry.recalled = true;
                            Recall::Kept {
                                object: retain(object),
                                age,
                                first,
                            }
                        }
                        None => Recall::Released { age },
                    }
                }
            },
        };
        (recall, released)
    }

    /// Every kept object, for the caller to release.
    pub fn drain(&mut self) -> Vec<Released> {
        self.entries.drain(..).filter_map(|e| e.object).collect()
    }

    /// How many objects are kept.
    pub fn kept(&self) -> usize {
        self.entries.iter().filter(|e| e.object.is_some()).count()
    }

    fn position(&self, kind: TypeId, reference: u32) -> Option<usize> {
        self.entries
            .iter()
            .rposition(|e| e.kind == kind && e.reference == reference)
    }

    /// Releases the objects past their kind's count or age, newest kept first, and forgets the
    /// oldest deletes past [`REMEMBERED`].
    fn prune(&mut self, now: MonoTime, released: &mut Vec<Released>) {
        let (mut resources, mut others) = (0usize, 0usize);
        for entry in self.entries.iter_mut().rev() {
            if entry.object.is_none() {
                continue;
            }
            let (count, limit, kept_for) = if entry.resource {
                (&mut resources, KEPT_RESOURCES, RESOURCE_KEPT_FOR)
            } else {
                (&mut others, KEPT_OTHERS, OTHER_KEPT_FOR)
            };
            *count = count.saturating_add(1);
            if *count > limit || now.saturating_duration_since(entry.at) > kept_for {
                released.extend(entry.object.take());
            }
        }
        while self.entries.len() > REMEMBERED {
            if let Some(old) = self.entries.pop_front() {
                released.extend(old.object);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    struct A;
    struct B;

    fn at(ms: u64) -> MonoTime {
        MonoTime::from_nanos(ms.saturating_mul(1_000_000))
    }

    fn past(d: Duration) -> u64 {
        u64::try_from(d.as_millis()).unwrap() + 1
    }

    fn count(n: usize) -> u32 {
        u32::try_from(n).unwrap()
    }

    fn recall(r: &mut Retired, kind: TypeId, reference: u32, ms: u64) -> Recall<Arc<u32>> {
        r.recall::<Arc<u32>>(kind, reference, at(ms), Arc::clone).0
    }

    #[test]
    fn a_deleted_object_is_recalled_and_stays_kept() {
        let mut r = Retired::default();
        let o = Arc::new(7u32);
        assert!(
            r.retire(TypeId::of::<A>(), 5, Some(Arc::clone(&o)), false, at(0))
                .is_empty()
        );
        match recall(&mut r, TypeId::of::<A>(), 5, 10) {
            Recall::Kept { object, age, first } => {
                assert!(Arc::ptr_eq(&object, &o));
                assert_eq!(age, Duration::from_millis(10));
                assert!(first);
            }
            _ => panic!("not kept"),
        }
        assert!(matches!(
            recall(&mut r, TypeId::of::<A>(), 5, 20),
            Recall::Kept { first: false, .. }
        ));
        assert_eq!(Arc::strong_count(&o), 2);
    }

    #[test]
    fn kinds_and_references_are_apart() {
        let mut r = Retired::default();
        r.retire(TypeId::of::<A>(), 5, Some(Arc::new(1u32)), false, at(0));
        assert!(matches!(
            recall(&mut r, TypeId::of::<B>(), 5, 0),
            Recall::Unknown
        ));
        assert!(matches!(
            recall(&mut r, TypeId::of::<A>(), 6, 0),
            Recall::Unknown
        ));
    }

    #[test]
    fn a_delete_without_an_object_is_remembered() {
        let mut r = Retired::default();
        r.retire::<Arc<u32>>(TypeId::of::<A>(), 5, None, false, at(0));
        assert!(matches!(
            recall(&mut r, TypeId::of::<A>(), 5, 4),
            Recall::Released { age } if age == Duration::from_millis(4)
        ));
    }

    #[test]
    fn a_resource_is_released_after_its_time() {
        let mut r = Retired::default();
        let o = Arc::new(1u32);
        r.retire(TypeId::of::<A>(), 5, Some(Arc::clone(&o)), true, at(0));
        let late = past(RESOURCE_KEPT_FOR);
        let (recall, released) = r.recall::<Arc<u32>>(TypeId::of::<A>(), 5, at(late), Arc::clone);
        assert!(matches!(recall, Recall::Released { .. }));
        assert_eq!(released.len(), 1);
        drop(released);
        assert_eq!(Arc::strong_count(&o), 1);
    }

    #[test]
    fn only_the_newest_resources_are_kept() {
        let mut r = Retired::default();
        let mut released = 0;
        for reference in 0..(count(KEPT_RESOURCES) + 2) {
            released += r
                .retire(
                    TypeId::of::<A>(),
                    reference,
                    Some(Arc::new(reference)),
                    true,
                    at(0),
                )
                .len();
        }
        assert_eq!(released, 2);
        assert_eq!(r.kept(), KEPT_RESOURCES);
        assert!(matches!(
            recall(&mut r, TypeId::of::<A>(), 0, 0),
            Recall::Released { .. }
        ));
        assert!(matches!(
            recall(&mut r, TypeId::of::<A>(), count(KEPT_RESOURCES) + 1, 0),
            Recall::Kept { .. }
        ));
    }

    #[test]
    fn other_kinds_outlast_resources() {
        let mut r = Retired::default();
        r.retire(TypeId::of::<A>(), 5, Some(Arc::new(1u32)), false, at(0));
        let late = past(RESOURCE_KEPT_FOR);
        assert!(matches!(
            recall(&mut r, TypeId::of::<A>(), 5, late),
            Recall::Kept { .. }
        ));
        let gone = past(OTHER_KEPT_FOR);
        assert!(matches!(
            recall(&mut r, TypeId::of::<A>(), 5, gone),
            Recall::Released { .. }
        ));
    }

    #[test]
    fn a_second_delete_replaces_the_first() {
        let mut r = Retired::default();
        let first = Arc::new(1u32);
        r.retire(TypeId::of::<A>(), 5, Some(Arc::clone(&first)), false, at(0));
        let released = r.retire(TypeId::of::<A>(), 5, Some(Arc::new(2u32)), false, at(1));
        assert_eq!(released.len(), 1);
        drop(released);
        assert_eq!(Arc::strong_count(&first), 1);
        match recall(&mut r, TypeId::of::<A>(), 5, 1) {
            Recall::Kept { object, .. } => assert_eq!(*object, 2),
            _ => panic!("not kept"),
        }
    }

    #[test]
    fn old_deletes_are_forgotten() {
        let mut r = Retired::default();
        for reference in 0..(count(REMEMBERED) + 1) {
            r.retire::<Arc<u32>>(TypeId::of::<A>(), reference, None, false, at(0));
        }
        assert!(matches!(
            recall(&mut r, TypeId::of::<A>(), 0, 0),
            Recall::Unknown
        ));
    }

    #[test]
    fn drain_releases_every_kept_object() {
        let mut r = Retired::default();
        r.retire(TypeId::of::<A>(), 1, Some(Arc::new(1u32)), false, at(0));
        r.retire(TypeId::of::<A>(), 2, Some(Arc::new(2u32)), true, at(0));
        assert_eq!(r.drain().len(), 2);
        assert_eq!(r.kept(), 0);
    }
}
