//! Hours and days in Unix time.
//!
//! Usage is booked to the start of the UTC hour it was measured in. "Today" starts at the most
//! recent reset hour in local time, rounded down to a whole UTC hour so it always falls on a
//! bucket boundary. In a time zone with a whole-hour offset the rounding changes nothing; in one
//! with a half-hour offset (India, +5:30) the day starts 30 minutes before the reset hour.

const HOUR: i64 = 3600;
const DAY: i64 = 24 * HOUR;

/// Start of the hour that contains `time`.
#[must_use]
pub fn hour_start(time: i64) -> i64 {
    time.div_euclid(HOUR) * HOUR
}

/// Start of the day that contains `now`, where a day begins at `reset_hour` local time.
///
/// `offset_at(t)` is the local time zone's offset from UTC in seconds at Unix time `t`
/// ([`local_offset`] for the Mac's zone).
#[must_use]
pub fn day_start(now: i64, reset_hour: u8, offset_at: impl Fn(i64) -> i64) -> i64 {
    let local = now + offset_at(now);
    let mut start_local = local.div_euclid(DAY) * DAY + i64::from(reset_hour) * HOUR;
    if start_local > local {
        start_local -= DAY;
    }
    // The offset at the start can differ from the offset now when daylight saving time changed
    // in between; read it near the start instead.
    let start = start_local - offset_at(start_local - offset_at(now));
    hour_start(start)
}

/// The Mac's time zone offset from UTC, in seconds, at Unix time `time`.
#[must_use]
pub fn local_offset(time: i64) -> i64 {
    let t: libc::time_t = time;
    // SAFETY: `tm` is plain data that `localtime_r` fills in; both pointers are valid for the call.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: as above.
    if unsafe { libc::localtime_r(&raw const t, &raw mut tm) }.is_null() {
        return 0;
    }
    tm.tm_gmtoff
}

/// Seconds since the Unix epoch, now.
#[must_use]
pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

#[cfg(test)]
mod tests {
    use super::{day_start, hour_start, local_offset};

    // 2026-10-27 00:00:00 UTC, a Tuesday.
    const MIDNIGHT_UTC: i64 = 1_793_059_200;
    const H: i64 = 3600;

    fn utc(_: i64) -> i64 {
        0
    }

    #[test]
    fn bytes_are_booked_to_the_start_of_their_hour() {
        assert_eq!(
            hour_start(MIDNIGHT_UTC + 10 * H + 59 * 60 + 59),
            MIDNIGHT_UTC + 10 * H
        );
        assert_eq!(hour_start(MIDNIGHT_UTC + 11 * H), MIDNIGHT_UTC + 11 * H);
        // Before 1970 the hour still starts at or before the time.
        assert_eq!(hour_start(-1), -H);
    }

    #[test]
    fn day_starts_at_midnight_by_default() {
        assert_eq!(day_start(MIDNIGHT_UTC + 15 * H, 0, utc), MIDNIGHT_UTC);
        assert_eq!(day_start(MIDNIGHT_UTC, 0, utc), MIDNIGHT_UTC);
        assert_eq!(day_start(MIDNIGHT_UTC - 1, 0, utc), MIDNIGHT_UTC - 24 * H);
    }

    #[test]
    fn before_the_reset_hour_today_is_still_yesterday() {
        // Reset at 04:00: at 03:59 the day began at 04:00 the day before; at 04:00 a new one starts.
        let reset = MIDNIGHT_UTC + 4 * H;
        assert_eq!(day_start(reset - 60, 4, utc), reset - 24 * H);
        assert_eq!(day_start(reset, 4, utc), reset);
        assert_eq!(day_start(MIDNIGHT_UTC + 23 * H, 4, utc), reset);
    }

    #[test]
    fn reset_hour_is_local_time() {
        // UTC+2: local midnight on 27 October is 22:00 UTC on the 26th.
        let plus_two = |_| 2 * H;
        assert_eq!(
            day_start(MIDNIGHT_UTC + H, 0, plus_two),
            MIDNIGHT_UTC - 2 * H
        );
        // UTC−5: at 03:00 UTC it is 22:00 on the 26th locally, so the day began at 05:00 UTC on
        // the 26th.
        let minus_five = |_| -5 * H;
        assert_eq!(
            day_start(MIDNIGHT_UTC + 3 * H, 0, minus_five),
            MIDNIGHT_UTC - 19 * H
        );
        // A reset hour of 6 in UTC−5 is 11:00 UTC.
        assert_eq!(
            day_start(MIDNIGHT_UTC + 12 * H, 6, minus_five),
            MIDNIGHT_UTC + 11 * H
        );
    }

    #[test]
    fn daylight_saving_change_after_the_reset_hour_keeps_the_local_reset_hour() {
        // A zone at UTC+1 that moves to UTC+2 at 01:00 UTC. At 12:00 UTC (14:00 local, +2) the day
        // began at local midnight, which was still +1: 23:00 UTC the day before.
        let change = MIDNIGHT_UTC + H;
        let zone = move |t: i64| if t >= change { 2 * H } else { H };
        assert_eq!(day_start(MIDNIGHT_UTC + 12 * H, 0, zone), MIDNIGHT_UTC - H);
    }

    #[test]
    fn half_hour_zone_rounds_the_day_down_to_a_bucket() {
        // UTC+5:30: local midnight on the 27th is 18:30 UTC on the 26th; the day starts at the
        // bucket that holds it, 18:00 UTC.
        let india = |_| 5 * H + 30 * 60;
        assert_eq!(
            day_start(MIDNIGHT_UTC + 6 * H, 0, india),
            MIDNIGHT_UTC - 6 * H
        );
    }

    #[test]
    fn local_offset_and_now_match_the_date_command() {
        // `date` prints the zone offset as +hhmm and the time as Unix seconds.
        let date = |args: &[&str]| {
            let out = std::process::Command::new("date")
                .args(args)
                .output()
                .unwrap();
            String::from_utf8(out.stdout).unwrap().trim().to_owned()
        };
        let zone = date(&["-r", &MIDNIGHT_UTC.to_string(), "+%z"]);
        let sign = if zone.starts_with('-') { -1 } else { 1 };
        let hours: i64 = zone[1..3].parse().unwrap();
        let minutes: i64 = zone[3..5].parse().unwrap();
        assert_eq!(
            local_offset(MIDNIGHT_UTC),
            sign * (hours * H + minutes * 60),
            "{zone}"
        );
        let shown: i64 = date(&["+%s"]).parse().unwrap();
        assert!(
            (super::now() - shown).abs() <= 2,
            "{} vs {shown}",
            super::now()
        );
    }
}
