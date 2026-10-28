//! The engine's self-check: the bytes credited to apps against the bytes that crossed the
//! interfaces, judged over 10-minute windows.
//!
//! Flows carry no packet headers, so the apps sum below the interfaces: 8–10% during a bulk
//! download, about 22% on an idle minute. The check therefore judges the gap only when a window
//! moved enough to make it meaningful:
//!
//! - A window with at least [`MIN_WINDOW_BYTES`] on the interfaces fails when the apps cover less
//!   than `100 - MAX_GAP_PERCENT` percent of it. Two failing windows in a row make the engine
//!   [`Verdict::Degraded`]; a passing one clears it. A window with less traffic is not judged and
//!   breaks the run of failures, but keeps the verdict it found.
//! - Apps summing to more than the interfaces by [`OVERCOUNT_PERCENT`] is reported at once, at
//!   any volume, because flows never carry more than crossed the wire. It stays reported until a
//!   whole window has passed without it.

use crate::meter::Bytes;

/// Length of a judged window, in seconds.
pub const WINDOW: i64 = 600;
/// Interface bytes a window needs before its gap is judged.
pub const MIN_WINDOW_BYTES: u64 = 10_000_000;
/// How far, in percent of the interface bytes, the apps may sum below the interfaces.
pub const MAX_GAP_PERCENT: u64 = 15;
/// How far, in percent of the interface bytes, the apps may sum above the interfaces.
pub const OVERCOUNT_PERCENT: u64 = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    /// Nothing wrong seen.
    Ok,
    /// Two windows in a row credited too little to apps.
    Degraded,
    /// Apps summed to more than crossed the interfaces.
    Overcount,
}

#[derive(Debug, Default, Clone)]
pub struct SelfCheck {
    /// Unix time the current window started; none before the first observation.
    window_start: Option<i64>,
    apps: u64,
    interfaces: u64,
    failing: u32,
    degraded: bool,
    /// The last closed window was over-counted.
    was_overcount: bool,
}

impl SelfCheck {
    /// Adds what one poll booked at `now`, and closes the window once it is [`WINDOW`] long.
    pub fn observe(&mut self, apps: Bytes, interfaces: Bytes, now: i64) {
        let start = *self.window_start.get_or_insert(now);
        self.apps += apps.total();
        self.interfaces += interfaces.total();
        if now - start >= WINDOW {
            self.close();
            self.window_start = Some(now);
        }
    }

    fn close(&mut self) {
        self.was_overcount = self.is_overcount();
        if self.interfaces >= MIN_WINDOW_BYTES {
            // apps / interfaces < (100 - gap) / 100, in integers.
            let fails = u128::from(self.apps) * 100
                < u128::from(self.interfaces) * u128::from(100 - MAX_GAP_PERCENT);
            if fails {
                self.failing += 1;
                if self.failing >= 2 {
                    self.degraded = true;
                }
            } else {
                self.failing = 0;
                self.degraded = false;
            }
        } else {
            self.failing = 0;
        }
        self.apps = 0;
        self.interfaces = 0;
    }

    fn is_overcount(&self) -> bool {
        u128::from(self.apps) * 100
            > u128::from(self.interfaces) * u128::from(100 + OVERCOUNT_PERCENT)
    }

    #[must_use]
    pub fn verdict(&self) -> Verdict {
        if self.is_overcount() || self.was_overcount {
            Verdict::Overcount
        } else if self.degraded {
            Verdict::Degraded
        } else {
            Verdict::Ok
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{SelfCheck, Verdict, WINDOW};
    use crate::meter::Bytes;

    const MB: u64 = 1_000_000;
    const T: i64 = 1_793_059_200;

    fn rx(rx: u64) -> Bytes {
        Bytes { rx, tx: 0 }
    }

    /// One whole window starting at `start`: two polls, the second closing it.
    fn window(check: &mut SelfCheck, start: i64, apps: u64, interfaces: u64) {
        check.observe(rx(apps / 2), rx(interfaces / 2), start);
        check.observe(
            rx(apps - apps / 2),
            rx(interfaces - interfaces / 2),
            start + WINDOW,
        );
    }

    #[test]
    fn a_bulk_download_with_the_usual_header_gap_is_ok() {
        let mut check = SelfCheck::default();
        // 20 MB on the interfaces, apps 8% below: what a curl download measured in M1.
        for i in 0..4 {
            window(&mut check, T + i * WINDOW, 18_400_000, 20 * MB);
        }
        assert_eq!(check.verdict(), Verdict::Ok);
    }

    #[test]
    fn two_failing_windows_in_a_row_are_degraded_and_one_is_not() {
        let mut check = SelfCheck::default();
        // Apps 80% of 20 MB: a 20% gap, over the 15% allowed.
        window(&mut check, T, 16 * MB, 20 * MB);
        assert_eq!(check.verdict(), Verdict::Ok, "one failing window");
        window(&mut check, T + WINDOW, 16 * MB, 20 * MB);
        assert_eq!(check.verdict(), Verdict::Degraded);
        // A passing window (10% gap) clears it.
        window(&mut check, T + 2 * WINDOW, 18 * MB, 20 * MB);
        assert_eq!(check.verdict(), Verdict::Ok);
    }

    #[test]
    fn the_gap_limit_is_fifteen_percent() {
        // 85% coverage passes, just under fails.
        let mut check = SelfCheck::default();
        window(&mut check, T, 17 * MB, 20 * MB);
        window(&mut check, T + WINDOW, 17 * MB, 20 * MB);
        assert_eq!(check.verdict(), Verdict::Ok);
        let mut check = SelfCheck::default();
        window(&mut check, T, 17 * MB - 1, 20 * MB);
        window(&mut check, T + WINDOW, 17 * MB - 1, 20 * MB);
        assert_eq!(check.verdict(), Verdict::Degraded);
    }

    #[test]
    fn an_idle_window_is_not_judged_however_large_its_gap() {
        let mut check = SelfCheck::default();
        // An idle Mac: apps 78% of 2 MB, the 22% gap measured in M1, in every window.
        for i in 0..6 {
            window(&mut check, T + i * WINDOW, 1_560_000, 2 * MB);
        }
        assert_eq!(check.verdict(), Verdict::Ok);
        // 10 MB is enough to be judged.
        window(&mut check, T + 6 * WINDOW, 7 * MB, 10 * MB);
        window(&mut check, T + 7 * WINDOW, 7 * MB, 10 * MB);
        assert_eq!(check.verdict(), Verdict::Degraded);
    }

    #[test]
    fn a_quiet_window_between_two_failing_ones_breaks_the_run() {
        let mut check = SelfCheck::default();
        window(&mut check, T, 16 * MB, 20 * MB);
        window(&mut check, T + WINDOW, MB / 2, MB);
        window(&mut check, T + 2 * WINDOW, 16 * MB, 20 * MB);
        assert_eq!(check.verdict(), Verdict::Ok);
    }

    #[test]
    fn a_quiet_window_keeps_a_degraded_verdict() {
        let mut check = SelfCheck::default();
        window(&mut check, T, 16 * MB, 20 * MB);
        window(&mut check, T + WINDOW, 16 * MB, 20 * MB);
        window(&mut check, T + 2 * WINDOW, MB / 2, MB);
        assert_eq!(check.verdict(), Verdict::Degraded);
    }

    #[test]
    fn apps_over_the_interfaces_flag_at_once_at_any_volume() {
        let mut check = SelfCheck::default();
        // 103 KB credited to apps of 100 KB on the wire, in the first poll of a window.
        check.observe(rx(103_000), rx(100_000), T);
        assert_eq!(check.verdict(), Verdict::Overcount);
        // 2% over is still allowed.
        let mut check = SelfCheck::default();
        check.observe(rx(102_000), rx(100_000), T);
        assert_eq!(check.verdict(), Verdict::Ok);
    }

    #[test]
    fn an_overcount_stays_reported_for_the_next_window_then_clears() {
        let mut check = SelfCheck::default();
        window(&mut check, T, 12 * MB, 10 * MB);
        // The window closed over-counted; the new one has nothing yet.
        assert_eq!(check.verdict(), Verdict::Overcount);
        window(&mut check, T + WINDOW, 9 * MB, 10 * MB);
        assert_eq!(check.verdict(), Verdict::Ok);
    }

    #[test]
    fn a_window_closes_after_ten_minutes_not_before() {
        let mut check = SelfCheck::default();
        check.observe(rx(16 * MB), rx(20 * MB), T);
        // Still the first window one second short of its end, then a second window.
        check.observe(Bytes::default(), Bytes::default(), T + WINDOW - 1);
        check.observe(Bytes::default(), Bytes::default(), T + WINDOW);
        check.observe(rx(16 * MB), rx(20 * MB), T + 2 * WINDOW - 1);
        assert_eq!(
            check.verdict(),
            Verdict::Ok,
            "the second window is still open"
        );
        check.observe(Bytes::default(), Bytes::default(), T + 2 * WINDOW);
        assert_eq!(check.verdict(), Verdict::Degraded);
    }
}
