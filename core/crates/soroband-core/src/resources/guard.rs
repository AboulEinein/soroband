//! The layout guard: checks that the coalition words the meter reads hold what it thinks they do.
//!
//! The coalition struct is not in the public SDK, so its layout could move in a macOS release.
//! The guard reads each coalition's members with `proc_pid_rusage` before and after the
//! coalition's own read, and compares each stored field with the members' sum. A coalition counts
//! the processes that exited too, so only coalitions with at most one exited process (the
//! launcher a process starts from) are compared, and their members must all be readable.
//!
//! A field is judged only on coalitions where no other stored field's value would also pass its
//! comparison, so a layout that swaps two fields cannot pass on coalitions where they happen to
//! agree. A field with no coalition to judge it on is not verified, and the layout fails.

use super::{Field, Layout, ProcessUsage, RAW_WORDS};

/// One coalition as the guard sees it: its words and each member's usage before and after.
#[derive(Debug, Clone)]
pub struct Sample {
    pub raw: [u64; RAW_WORDS],
    pub before: Vec<Option<ProcessUsage>>,
    pub after: Vec<Option<ProcessUsage>>,
}

/// Exited processes a coalition may hold and still be compared: the launcher its first process
/// was started from (`xpcproxy`) exits when it hands over.
const MAX_EXITED: u64 = 1;

/// Share of the judged coalitions that must agree for a field to pass.
const AGREEING: f64 = 0.9;

/// How far a coalition's field may sit from its members' sum: below the sum before the read, and
/// above the sum after it. Measured on a Mac with macOS 27 (`prototypes/sysmon-probe`, and M8's
/// pull request): the coalition's CPU time ran 0–15% below the members' user and system time, and
/// billed time up to 53% below on a few coalitions; the other fields matched exactly.
fn tolerance(field: Field) -> (f64, f64) {
    match field {
        Field::Cpu => (0.80, 1.02),
        Field::Billed => (0.40, 1.02),
        Field::Read | Field::Written | Field::Energy | Field::Footprint => (0.98, 1.02),
    }
}

/// Whether `value` could be `field` of a coalition whose members summed to `low` before its read
/// and `high` after it.
fn accepts(field: Field, value: u64, low: u64, high: u64) -> bool {
    #[allow(clippy::cast_precision_loss)] // within a per-mille of any real value
    let (value, low, high) = (value as f64, low as f64, high as f64);
    let (below, above) = tolerance(field);
    value >= low * below && value <= high * above
}

/// Checks `layout` against `samples`. Returns why it fails, naming the first field that does.
///
/// # Errors
/// When a field is judged on no coalition, or fewer than 90% of the coalitions it is judged on
/// agree with their members.
pub fn check(layout: &Layout, samples: &[Sample]) -> Result<(), String> {
    for field in Field::ALL {
        let mut judged = 0u32;
        let mut agreed = 0u32;
        for sample in samples {
            if sample.raw[layout.exited] > MAX_EXITED || sample.before.is_empty() {
                continue;
            }
            let Some((low, high)) = bounds(sample, field) else {
                continue;
            };
            // Judged only where no other field's processes sum to a value this one would
            // accept, so a layout that swaps the two cannot pass here.
            let ambiguous = Field::ALL
                .iter()
                .filter(|&&other| other != field)
                .filter_map(|&other| bounds(sample, other))
                .any(|(other_low, other_high)| {
                    accepts(field, other_low, low, high) || accepts(field, other_high, low, high)
                });
            if ambiguous {
                continue;
            }
            judged += 1;
            if accepts(field, sample.raw[layout.index(field)], low, high) {
                agreed += 1;
            }
        }
        if judged == 0 {
            return Err(format!("{}: no coalition to compare it on", field.name()));
        }
        if f64::from(agreed) < f64::from(judged) * AGREEING {
            return Err(format!(
                "{}: {agreed} of {judged} coalitions agree with their processes",
                field.name()
            ));
        }
    }
    Ok(())
}

/// The members' sum of `field` before and after the coalition's read, lowest first (a footprint
/// is not a counter: it can shrink between the two), or `None` if a member could not be read.
fn bounds(sample: &Sample, field: Field) -> Option<(u64, u64)> {
    let (before, after) = (sum(&sample.before, field)?, sum(&sample.after, field)?);
    Some((before.min(after), before.max(after)))
}

/// `field` summed over the members, or `None` if one could not be read.
fn sum(members: &[Option<ProcessUsage>], field: Field) -> Option<u64> {
    members
        .iter()
        .map(|usage| usage.map(|u| u.field(field)))
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::resources::LAYOUT;

    fn usage(cpu: u64, footprint: u64) -> ProcessUsage {
        ProcessUsage {
            cpu,
            billed: cpu / 10,
            read: cpu * 3,
            written: cpu * 5,
            energy: cpu * 7,
            footprint,
            start: 0,
        }
    }

    /// A coalition whose words match its one member exactly.
    fn sample(cpu: u64, footprint: u64) -> Sample {
        let member = usage(cpu, footprint);
        let mut raw = [0; RAW_WORDS];
        for field in Field::ALL {
            raw[LAYOUT.index(field)] = member.field(field);
        }
        Sample {
            raw,
            before: vec![Some(member)],
            after: vec![Some(member)],
        }
    }

    #[test]
    fn matching_coalitions_pass() {
        let samples: Vec<Sample> = (1..20).map(|n| sample(n * 1_000, n * 999_983)).collect();
        assert_eq!(check(&LAYOUT, &samples), Ok(()));
    }

    #[test]
    fn swapped_fields_fail() {
        let samples: Vec<Sample> = (1..20).map(|n| sample(n * 1_000, n * 999_983)).collect();
        let mut swapped = LAYOUT;
        std::mem::swap(&mut swapped.read, &mut swapped.written);
        assert_eq!(
            check(&swapped, &samples),
            Err("disk read: 0 of 19 coalitions agree with their processes".into())
        );
    }

    #[test]
    fn a_field_whose_value_another_field_shares_is_not_judged_there() {
        // Read and written agree on every coalition, so a swap of the two cannot be told apart
        // and the layout cannot be verified.
        let samples: Vec<Sample> = (1..20)
            .map(|n| {
                let mut s = sample(n * 1_000, n * 999_983);
                for side in [&mut s.before, &mut s.after] {
                    side[0].as_mut().unwrap().written = n * 3_000;
                }
                s.raw[LAYOUT.written] = n * 3_000;
                s
            })
            .collect();
        assert_eq!(
            check(&LAYOUT, &samples),
            Err("disk read: no coalition to compare it on".into())
        );
    }

    #[test]
    fn coalitions_with_exited_or_unreadable_processes_are_not_compared() {
        let mut exited = sample(5_000, 4_000_000);
        exited.raw[LAYOUT.exited] = 2;
        exited.raw[LAYOUT.cpu] = 900_000;
        let mut unreadable = sample(5_000, 4_000_000);
        unreadable.after.push(None);
        unreadable.before.push(None);
        unreadable.raw[LAYOUT.cpu] = 900_000;
        let samples = vec![sample(1_000, 3_000_000), exited, unreadable];
        assert_eq!(check(&LAYOUT, &samples), Ok(()));
    }

    #[test]
    fn coalition_cpu_may_trail_its_processes() {
        let mut s = sample(10_000, 4_000_000);
        s.raw[LAYOUT.cpu] = 8_500;
        assert_eq!(check(&LAYOUT, &[s.clone()]), Ok(()));
        s.raw[LAYOUT.cpu] = 7_900;
        assert!(check(&LAYOUT, &[s]).is_err());
    }

    #[test]
    fn a_counter_may_run_a_little_past_its_processes_read_after_it() {
        let mut s = sample(10_000, 4_000_000);
        s.raw[LAYOUT.read] = 30_300; // 1% over the members' 30,000
        assert_eq!(check(&LAYOUT, &[s.clone()]), Ok(()));
        s.raw[LAYOUT.read] = 30_700; // 2.3% over
        assert!(check(&LAYOUT, &[s]).is_err());
    }

    #[test]
    fn a_field_is_not_judged_where_another_field_passed_through_its_range_between_the_reads() {
        // Written grew from what read is (30,000) to far above it between the two reads: a
        // swap of the two could pass here, so read is not judged.
        let mut s = sample(10_000, 4_000_000);
        s.before[0].as_mut().unwrap().written = 30_000;
        s.after[0].as_mut().unwrap().written = 90_000;
        s.raw[LAYOUT.written] = 70_000;
        assert_eq!(
            check(&LAYOUT, &[s]),
            Err("disk read: no coalition to compare it on".into())
        );
    }

    #[test]
    fn nine_of_ten_coalitions_agreeing_is_enough() {
        let mut samples: Vec<Sample> = (1..=10).map(|n| sample(n * 1_000, n * 999_983)).collect();
        samples[0].raw[LAYOUT.energy] = 1;
        assert_eq!(check(&LAYOUT, &samples), Ok(()));
        samples[1].raw[LAYOUT.energy] = 1;
        assert_eq!(
            check(&LAYOUT, &samples),
            Err("energy: 8 of 10 coalitions agree with their processes".into())
        );
    }
}
