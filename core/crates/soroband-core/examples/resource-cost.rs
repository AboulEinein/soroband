//! Times the resource meter on this Mac: the first read (with the layout guard), then reads
//! half a second apart, beside the kernel calls a read makes.
//!
//! Usage: cargo run --release --example resource-cost

use soroband_core::resources::kernel::SystemResources;
use soroband_core::resources::{ResourceHost, ResourceMeter};
use std::time::{Duration, Instant};

fn main() {
    let mut meter = ResourceMeter::new(SystemResources::new());
    let t = Instant::now();
    meter.read(0);
    println!("first read, with the guard: {:?}", t.elapsed());
    for i in 1..=5 {
        std::thread::sleep(Duration::from_millis(500));
        let t = Instant::now();
        let reading = meter.read(i * 60);
        println!("read: {:?}, {} apps", t.elapsed(), reading.apps.len());
    }
    let mut host = SystemResources::new();
    let ids = host.coalition_ids().expect("coalition calls");
    let t = Instant::now();
    for &id in &ids {
        std::hint::black_box(host.coalition_usage(id));
    }
    println!(
        "the {} coalitions' words alone: {:?}",
        ids.len(),
        t.elapsed()
    );
    let t = Instant::now();
    for _ in 0..1000 {
        std::hint::black_box(host.gauges());
    }
    println!("gauges: {:?} each", t.elapsed() / 1000);
}
