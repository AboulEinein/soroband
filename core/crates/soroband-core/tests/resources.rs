//! Replays of recorded resource reads through the resource meter.
//!
//! `tests/fixtures/resources-yes-dd.json` was recorded on macOS 27 (M2 Max) with
//! the `record-resources` example, run as a launchd job: three whole reads, the first before the
//! recorder started `/usr/bin/yes` and a `/bin/dd` writing 64 MB, the second a second later while
//! `yes` ran (`dd` had finished), the third a second after `yes` was killed. Both ran in the
//! recorder's coalition, which they shared with it. The CPU time `yes` and `dd` used by their own
//! account (`wait4`) is under `"expect"`. Paths outside macOS's own directories are made up.

use soroband_core::resources::record::{Recording, Replay};
use soroband_core::resources::{Counters, Field, LAYOUT, Layout, Reading, ResourceMeter, Source};

fn fixture() -> (Recording, serde_json::Value) {
    let path = format!(
        "{}/tests/fixtures/resources-yes-dd.json",
        env!("CARGO_MANIFEST_DIR")
    );
    let text = std::fs::read_to_string(path).expect("fixture");
    let expect = serde_json::from_str::<serde_json::Value>(&text).expect("json")["expect"].clone();
    (Recording::parse(&text).expect("recording"), expect)
}

/// Every read of the fixture through a meter with `layout`.
fn replay(layout: Layout) -> Vec<Reading> {
    let (recording, _) = fixture();
    let reads = recording.reads.len();
    let mut meter = ResourceMeter::with_layout(Replay::new(recording), layout);
    (0..reads)
        .map(|i| meter.read(i64::try_from(i).unwrap() * 60))
        .collect()
}

fn credited(readings: &[Reading], name: &str) -> u64 {
    readings
        .iter()
        .flat_map(|r| &r.apps)
        .filter(|(app, _)| app.name == name)
        .map(|(_, r)| r.counters.cpu)
        .sum()
}

#[test]
fn the_recorded_layout_passes_the_guard() {
    let readings = replay(LAYOUT);
    assert!(readings.iter().all(|r| r.source == Source::Coalitions));
    assert_eq!(readings[0].seconds, 0.0, "the first read is the baseline");
    assert!(
        readings[0]
            .apps
            .iter()
            .all(|(_, r)| r.counters == Counters::default())
    );
}

#[test]
fn a_command_in_a_shared_coalition_keeps_its_cpu_after_it_exits() {
    let (_, expect) = fixture();
    let yes = expect["yes_cpu_ns"].as_u64().unwrap();
    let readings = replay(LAYOUT);
    // Started after the first read: all of it from the second. Killed before the third: what it
    // used since the second comes from the coalition's growth.
    let got = credited(&readings, "yes");
    #[allow(clippy::cast_precision_loss)]
    let ratio = got as f64 / yes as f64;
    assert!(
        (0.95..=1.05).contains(&ratio),
        "yes: {got} ns against {yes} ns"
    );
}

#[test]
fn a_command_that_starts_and_exits_between_reads_goes_to_the_coalitions_leader() {
    // `dd` ran between the first and second reads, so no read saw it.
    let readings = replay(LAYOUT);
    assert_eq!(credited(&readings, "dd"), 0);
}

#[test]
fn coalitions_fold_into_apps() {
    let readings = replay(LAYOUT);
    for reading in &readings {
        let mut names: Vec<&str> = reading.apps.iter().map(|(a, _)| a.id.as_str()).collect();
        let count = names.len();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), count, "one row per app");
    }
    let services = readings[1]
        .apps
        .iter()
        .find(|(a, _)| a.name == "macOS & Services")
        .expect("services");
    assert!(services.1.counters.cpu > 0 && services.1.footprint > 0);
}

/// Every layout that moves one stored field to the next word, or swaps two of them.
fn broken_layouts() -> Vec<(String, Layout)> {
    let mut layouts = Vec::new();
    for field in Field::ALL {
        let mut moved = LAYOUT;
        let slot = match field {
            Field::Cpu => &mut moved.cpu,
            Field::Billed => &mut moved.billed,
            Field::Read => &mut moved.read,
            Field::Written => &mut moved.written,
            Field::Energy => &mut moved.energy,
            Field::Footprint => &mut moved.footprint,
        };
        *slot += 1;
        layouts.push((format!("{} moved", field.name()), moved));
    }
    for (i, a) in Field::ALL.iter().enumerate() {
        for b in &Field::ALL[i + 1..] {
            let mut swapped = LAYOUT;
            let (x, y) = (swapped.index(*a), swapped.index(*b));
            set(&mut swapped, *a, y);
            set(&mut swapped, *b, x);
            layouts.push((format!("{} and {} swapped", a.name(), b.name()), swapped));
        }
    }
    layouts
}

fn set(layout: &mut Layout, field: Field, index: usize) {
    match field {
        Field::Cpu => layout.cpu = index,
        Field::Billed => layout.billed = index,
        Field::Read => layout.read = index,
        Field::Written => layout.written = index,
        Field::Energy => layout.energy = index,
        Field::Footprint => layout.footprint = index,
    }
}

#[test]
fn a_moved_or_swapped_field_fails_the_guard_and_the_fallback_takes_over() {
    for (name, layout) in broken_layouts() {
        let readings = replay(layout);
        assert!(
            readings.iter().all(Reading::fallback),
            "{name}: {:?}",
            readings[0].source
        );
        // The fallback reads the user's processes: `yes` started after the first read.
        assert!(credited(&readings, "yes") > 0, "{name}");
    }
}

#[test]
fn the_service_writes_what_it_read_to_the_store() {
    use soroband_core::resources::service::ResourceService;
    use soroband_core::store::{ResourceOrder, Store};
    use std::sync::{Arc, Mutex};
    let (recording, expect) = fixture();
    let dir = std::env::temp_dir().join(format!("soroband-resources-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let store = Arc::new(Mutex::new(Store::open(&dir.join("usage.sqlite")).unwrap()));
    let hour = 1_800_000_000 / 3600 * 3600;
    let mut service = ResourceService::new(
        ResourceMeter::new(Replay::new(recording)),
        Arc::clone(&store),
        7,
        hour,
    );
    // A minute apart, so each poll reads; the second and third write.
    for i in 0..3 {
        service.poll(hour + i * 60).unwrap();
    }
    service.write(hour + 180, true).unwrap();
    let totals = store
        .lock()
        .unwrap()
        .resource_totals(hour, hour + 3600, ResourceOrder::Cpu)
        .unwrap();
    let yes = totals.iter().find(|t| t.app.name == "yes").expect("yes");
    let want = expect["yes_cpu_ns"].as_u64().unwrap();
    assert!(
        yes.counters.cpu.abs_diff(want) * 20 < want,
        "{} against {want}",
        yes.counters.cpu
    );
    assert!(totals.iter().all(|t| !t.fallback));
    let minutes: i64 = store.lock().unwrap().resource_minute_count().unwrap();
    assert_eq!(minutes, 3, "one row per minute polled");
}
