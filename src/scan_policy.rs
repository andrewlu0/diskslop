use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

use crate::Progress;

unsafe extern "C" {
    fn dt_physical_cores() -> usize;
    fn dt_scan_limit(ceiling: usize) -> usize;
    fn dt_scan_is_background() -> bool;
    fn dt_scan_worker_start(background: bool);
}

pub fn default_threads() -> usize {
    let available = std::thread::available_parallelism().map_or(4, usize::from);
    let physical = unsafe { dt_physical_cores() };
    let cores = if physical == 0 {
        available
    } else {
        available.min(physical)
    };
    cores.saturating_sub(cores.div_ceil(4)).clamp(1, 8)
}

pub(super) fn worker_priority() -> impl Fn(usize) {
    let background = unsafe { dt_scan_is_background() };
    move |_| unsafe { dt_scan_worker_start(background) }
}

const INTERVAL: Duration = Duration::from_secs(1);

struct State {
    active: usize,
    limit: usize,
    next_check: Instant,
}

pub(super) struct ScanBudget {
    ceiling: usize,
    state: Mutex<State>,
    changed: Condvar,
}

impl ScanBudget {
    pub(super) fn new(ceiling: usize) -> Self {
        Self {
            ceiling,
            state: Mutex::new(State {
                active: 0,
                limit: unsafe { dt_scan_limit(ceiling) },
                next_check: Instant::now() + INTERVAL,
            }),
            changed: Condvar::new(),
        }
    }

    pub(super) fn enter(&self, progress: &Progress) -> std::io::Result<Permit<'_>> {
        let mut state = self.state.lock().unwrap();
        loop {
            progress.check()?;
            let now = Instant::now();
            if now >= state.next_check {
                state.limit = unsafe { dt_scan_limit(self.ceiling) };
                state.next_check = now + INTERVAL;
                self.changed.notify_all();
            }
            if state.active < state.limit {
                state.active += 1;
                return Ok(Permit(self));
            }
            let remaining = state.next_check.saturating_duration_since(now);
            state = self.changed.wait_timeout(state, remaining).unwrap().0;
        }
    }
}

pub(super) struct Permit<'a>(&'a ScanBudget);
impl Drop for Permit<'_> {
    fn drop(&mut self) {
        let mut state = self.0.state.lock().unwrap();
        state.active -= 1;
        if state.limit < self.0.ceiling && state.active < state.limit {
            self.0.changed.notify_one();
        }
    }
}
