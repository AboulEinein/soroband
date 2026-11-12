//! The resource meter's rules on reads built by hand, one rule per test, with the expected numbers
//! worked out in each. The timebase is 1/1, so CPU times are in nanoseconds as given.

use soroband_core::resources::record::{RecordedProcess, RecordedRead, Recording, Replay};
use soroband_core::resources::{
    Counters, Gauges, LAYOUT, ProcessUsage, RAW_WORDS, Reading, ResourceMeter, Source,
};

const LEADER: &str = "/Applications/Term.app/Contents/MacOS/Term";
const TOOL: &str = "/opt/bin/tool";
const OTHER: &str = "/opt/bin/other";

/// A coalition's words with `cpu` CPU time (and disk written ten times it), `exited` processes
/// that exited, and `footprint`.
fn coalition(id: u64, cpu: u64, exited: u64, footprint: u64) -> (u64, [u64; RAW_WORDS]) {
    let mut raw = [0; RAW_WORDS];
    raw[LAYOUT.exited] = exited;
    raw[LAYOUT.cpu] = cpu;
    raw[LAYOUT.written] = cpu * 10;
    raw[LAYOUT.footprint] = footprint;
    (id, raw)
}

fn process(pid: u32, coalition: u64, path: &str, cpu: u64, start: u64) -> RecordedProcess {
    RecordedProcess {
        pid,
        coalition: Some(coalition),
        path: Some(path.into()),
        usage: vec![ProcessUsage {
            cpu,
            written: cpu * 10,
            footprint: 1_000 + u64::from(pid),
            start,
            ..ProcessUsage::default()
        }],
    }
}

fn unreadable(pid: u32, coalition: u64, path: &str) -> RecordedProcess {
    RecordedProcess {
        usage: Vec::new(),
        ..process(pid, coalition, path, 0, 0)
    }
}

fn read(
    time: u64,
    coalitions: Vec<(u64, [u64; RAW_WORDS])>,
    processes: Vec<RecordedProcess>,
) -> RecordedRead {
    RecordedRead {
        time,
        coalitions: Some(coalitions),
        processes,
        gauges: Gauges::default(),
        volumes: Vec::new(),
    }
}

/// Every read through a meter that skips the guard (its coalitions have no readable members to
/// compare, so it would fail): the layout is trusted, as on a Mac where the check passed.
fn run(reads: Vec<RecordedRead>, timebase: (u32, u32)) -> Vec<Reading> {
    let count = reads.len();
    let mut meter = ResourceMeter::trusting(Replay::new(Recording { timebase, reads }));
    (0..count)
        .map(|i| meter.read(i64::try_from(i).unwrap() * 60))
        .collect()
}

fn cpu(reading: &Reading, path: &str) -> u64 {
    let name = path.rsplit('/').next().unwrap();
    reading
        .apps
        .iter()
        .find(|(a, _)| a.name == name)
        .map_or(0, |(_, r)| r.counters.cpu)
}

#[test]
fn seconds_between_reads_follow_the_timebase() {
    let reads = vec![
        read(6_000_000_000, vec![coalition(1, 0, 0, 0)], vec![]),
        read(30_000_000_000, vec![coalition(1, 0, 0, 0)], vec![]),
    ];
    // 24e9 Mach units between them, at 125/3 ns each: 1000 s.
    let readings = run(reads, (125, 3));
    assert_eq!(readings[1].seconds, 1000.0);
}

#[test]
fn cpu_time_is_converted_with_the_timebase() {
    let reads = vec![
        read(
            0,
            vec![coalition(1, 0, 0, 0)],
            vec![process(10, 1, LEADER, 0, 0)],
        ),
        read(
            3,
            vec![coalition(1, 24, 0, 0)],
            vec![process(10, 1, LEADER, 24, 0)],
        ),
    ];
    assert_eq!(cpu(&run(reads, (125, 3))[1], LEADER), 1_000);
}

#[test]
fn a_new_coalition_counts_whole_and_an_unseen_older_one_takes_a_baseline() {
    let reads = vec![
        read(
            0,
            vec![coalition(5, 0, 0, 0)],
            vec![process(50, 5, LEADER, 0, 0)],
        ),
        read(
            100,
            vec![
                coalition(5, 7, 0, 0),
                coalition(9, 40, 0, 0),
                coalition(3, 900, 0, 0),
            ],
            vec![
                process(50, 5, LEADER, 7, 0),
                process(90, 9, TOOL, 40, 50),
                process(30, 3, OTHER, 900, 0),
            ],
        ),
        read(
            200,
            vec![
                coalition(5, 7, 0, 0),
                coalition(9, 41, 0, 0),
                coalition(3, 905, 0, 0),
            ],
            vec![
                process(50, 5, LEADER, 7, 0),
                process(90, 9, TOOL, 41, 50),
                process(30, 3, OTHER, 905, 0),
            ],
        ),
    ];
    let readings = run(reads, (1, 1));
    // Coalition 9 is above the first read's highest id: it started since, all of it is new.
    assert_eq!(cpu(&readings[1], TOOL), 40);
    // Coalition 3 is below it: it was there and not read (it could not be), so only its growth
    // from now on counts.
    assert_eq!(cpu(&readings[1], OTHER), 0);
    assert_eq!(cpu(&readings[2], OTHER), 5);
    assert_eq!(cpu(&readings[1], LEADER), 7);
}

#[test]
fn a_coalition_of_one_app_is_credited_its_own_counters() {
    // The member's own read says 3; the coalition, which also holds what exited, says 8.
    let reads = vec![
        read(
            0,
            vec![coalition(1, 0, 0, 0)],
            vec![process(10, 1, LEADER, 0, 0)],
        ),
        read(
            10,
            vec![coalition(1, 8, 1, 500)],
            vec![process(10, 1, LEADER, 3, 0)],
        ),
    ];
    let readings = run(reads, (1, 1));
    assert_eq!(cpu(&readings[1], LEADER), 8);
    assert_eq!(readings[1].apps[0].1.footprint, 500);
}

/// A terminal (pid 10) running a tool (pid 20) in coalition 1, read four times, each 10 apart.
fn terminal(tool_exits_seen: bool) -> Vec<Reading> {
    let exited_at_last = if tool_exits_seen { 1 } else { 2 };
    run(
        vec![
            read(
                0,
                vec![coalition(1, 0, 0, 0)],
                vec![process(10, 1, LEADER, 0, 0), process(20, 1, TOOL, 0, 0)],
            ),
            read(
                10,
                vec![coalition(1, 30, 0, 9_000)],
                vec![process(10, 1, LEADER, 10, 0), process(20, 1, TOOL, 20, 0)],
            ),
            // The tool exits; the coalition grew 50: 5 the terminal's, the rest the tool's last
            // moments, and, when an unseen process also exited, that one's.
            read(
                20,
                vec![coalition(1, 80, exited_at_last, 9_000)],
                vec![process(10, 1, LEADER, 15, 0)],
            ),
            // Nothing is gone since: the coalition holds one app again.
            read(
                30,
                vec![coalition(1, 90, exited_at_last, 9_000)],
                vec![process(10, 1, LEADER, 16, 0)],
            ),
        ],
        (1, 1),
    )
}

#[test]
fn a_shared_coalition_credits_each_member_its_own_growth() {
    let readings = terminal(true);
    assert_eq!(cpu(&readings[1], TOOL), 20);
    assert_eq!(cpu(&readings[1], LEADER), 10);
    // The leader takes the footprint no member's own read accounts for.
    let leader = readings[1]
        .apps
        .iter()
        .find(|(a, _)| a.name == "Term")
        .unwrap();
    assert_eq!(leader.1.footprint, 9_000 - 1_020);
}

#[test]
fn a_member_that_exited_keeps_the_rest_when_every_exit_was_seen() {
    let readings = terminal(true);
    // One process exited and it was read before: all 45 left are the tool's.
    assert_eq!(cpu(&readings[2], TOOL), 45);
    assert_eq!(cpu(&readings[2], LEADER), 5);
    // Then the coalition is the terminal's alone: its whole growth.
    assert_eq!(cpu(&readings[3], LEADER), 10);
    assert_eq!(cpu(&readings[3], TOOL), 0);
}

#[test]
fn a_member_that_exited_gets_at_most_its_earlier_rate_when_an_unseen_process_also_exited() {
    let readings = terminal(false);
    // 20 in the 10 before, so at most 20 in these 10; the leader takes the other 25.
    assert_eq!(cpu(&readings[2], TOOL), 20);
    assert_eq!(cpu(&readings[2], LEADER), 30);
}

#[test]
fn an_unreadable_member_caps_what_the_exited_ones_get() {
    let readings = run(
        vec![
            read(
                0,
                vec![coalition(1, 0, 0, 0)],
                vec![
                    process(10, 1, LEADER, 0, 0),
                    process(20, 1, TOOL, 0, 0),
                    unreadable(30, 1, OTHER),
                ],
            ),
            read(
                10,
                vec![coalition(1, 30, 0, 0)],
                vec![
                    process(10, 1, LEADER, 10, 0),
                    process(20, 1, TOOL, 20, 0),
                    unreadable(30, 1, OTHER),
                ],
            ),
            read(
                20,
                vec![coalition(1, 80, 1, 0)],
                vec![process(10, 1, LEADER, 15, 0), unreadable(30, 1, OTHER)],
            ),
        ],
        (1, 1),
    );
    // The unreadable member may have used some of the 45: the tool gets its rate, 20.
    assert_eq!(cpu(&readings[2], TOOL), 20);
    assert_eq!(cpu(&readings[2], LEADER), 30);
    assert_eq!(cpu(&readings[2], OTHER), 0);
}

#[test]
fn two_members_that_exited_share_the_rest_by_their_earlier_rates() {
    let readings = run(
        vec![
            read(
                0,
                vec![coalition(1, 0, 0, 0)],
                vec![
                    process(10, 1, LEADER, 0, 0),
                    process(20, 1, TOOL, 0, 0),
                    process(30, 1, OTHER, 0, 0),
                ],
            ),
            read(
                10,
                vec![coalition(1, 40, 0, 0)],
                vec![
                    process(10, 1, LEADER, 10, 0),
                    process(20, 1, TOOL, 20, 0),
                    process(30, 1, OTHER, 10, 0),
                ],
            ),
            read(
                20,
                vec![coalition(1, 70, 2, 0)],
                vec![process(10, 1, LEADER, 10, 0)],
            ),
        ],
        (1, 1),
    );
    // 30 left, shared 2:1.
    assert_eq!(cpu(&readings[2], TOOL), 20);
    assert_eq!(cpu(&readings[2], OTHER), 10);
    assert_eq!(cpu(&readings[2], LEADER), 0);
}

#[test]
fn a_process_counts_whole_only_when_it_started_since_the_last_read() {
    let readings = run(
        vec![
            read(
                100,
                vec![coalition(1, 0, 0, 0)],
                vec![process(10, 1, LEADER, 0, 0), process(20, 1, TOOL, 0, 0)],
            ),
            // pid 30 started at 150, after the read at 100: all of its 7 count. pid 40 started at
            // 90, before it, but was not read then (it was not in this coalition): a baseline.
            read(
                200,
                vec![coalition(1, 1_000, 0, 0)],
                vec![
                    process(10, 1, LEADER, 0, 0),
                    process(20, 1, TOOL, 50, 0),
                    process(30, 1, OTHER, 7, 150),
                    process(40, 1, "/opt/bin/late", 500, 90),
                ],
            ),
            // pid 20 was replaced by a new process with the same pid (a later start): all of the
            // new one's 3 count, not 3 less the old one's 50.
            read(
                300,
                vec![coalition(1, 1_010, 0, 0)],
                vec![
                    process(10, 1, LEADER, 0, 0),
                    process(20, 1, TOOL, 3, 250),
                    process(30, 1, OTHER, 7, 150),
                    process(40, 1, "/opt/bin/late", 500, 90),
                ],
            ),
        ],
        (1, 1),
    );
    assert_eq!(cpu(&readings[1], OTHER), 7);
    assert_eq!(cpu(&readings[1], "/opt/bin/late"), 0);
    assert_eq!(cpu(&readings[2], TOOL), 3);
}

#[test]
fn a_reused_pid_takes_its_new_executable() {
    let readings = run(
        vec![
            read(
                0,
                vec![coalition(1, 0, 0, 0)],
                vec![process(10, 1, LEADER, 0, 0)],
            ),
            read(
                10,
                vec![coalition(1, 0, 0, 0), coalition(2, 0, 0, 0)],
                vec![],
            ),
            read(
                20,
                vec![coalition(1, 0, 0, 0), coalition(2, 5, 0, 0)],
                vec![process(10, 2, TOOL, 5, 15)],
            ),
        ],
        (1, 1),
    );
    assert_eq!(cpu(&readings[2], TOOL), 5);
    assert_eq!(cpu(&readings[2], LEADER), 0);
}

#[test]
fn without_the_coalition_calls_the_meter_reads_processes() {
    let mut reads = vec![
        read(0, vec![], vec![process(10, 1, LEADER, 0, 0)]),
        read(10, vec![], vec![process(10, 1, LEADER, 4, 0)]),
    ];
    for r in &mut reads {
        r.coalitions = None;
    }
    let readings = run(reads, (1, 1));
    assert!(matches!(
        &readings[0].source,
        Source::Processes { reason } if reason.contains("missing")
    ));
    assert!(readings[1].fallback());
    assert_eq!(cpu(&readings[1], LEADER), 4);
    assert_eq!(readings[1].apps[0].1.counters.written, 40);
}

#[test]
fn counters_add_and_subtract_field_by_field() {
    let a = Counters {
        cpu: 5,
        billed: 4,
        read: 3,
        written: 2,
        energy: 1,
    };
    let mut sum = a;
    sum += a;
    assert_eq!(sum.saturating_sub(a), a);
    assert_eq!(a.saturating_sub(sum), Counters::default());
}
