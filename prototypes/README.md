# prototypes

Throwaway code that settled the design. Not built, tested or shipped; kept as a reference for the product code in `app/` and `core/`.

| Prototype | What it answered |
| --- | --- |
| `meter-probe` | Can we count per-app internet bytes from the kernel statistics socket ourselves, accurately and cheaply? Yes: 0.035–0.058% CPU, 2 MB. |
| `nstat-probe` | The same through Apple's private `NetworkStatistics.framework`, for comparison: 0.31% CPU, 7.8 MB. |
| `ui-spike` | The look and feel of the menu bar item, popover, history window, settings and Dynamic Island moments, on fake data. |
| `island-spike` | Where does the island run, and drawn with what? In the menu bar process, with AppKit: an AppKit agent grew 3.8–4.3 MB after 30 moments with the island in Core Animation, 5.5–5.7 MB with the ui-spike's SwiftUI view, both at 0.001% CPU at rest; screenshots differ in under 0.15% of pixels and recordings match frame by frame. `run.sh` repeats the measurement; `--record` films a cycle. |
| `popover-spike` | Does option C's popover keep less memory after closing in AppKit than in SwiftUI? A little: after 20 open/close cycles, 20.4 MB in AppKit, 23.7 MB in SwiftUI, 29.6 MB in SwiftUI with Swift Charts, from 9.4 MB at launch (an empty popover: 10.8 MB). The cost is paid at the first open and does not grow; `malloc_zone_pressure_relief` returns none of it. `run.sh` repeats the measurement. |
| `sysmon-probe` | Can Soroband meter CPU, memory and disk per app within its budget, and from which kernel interface? Yes, through coalitions (the kernel's group of an app and its helpers): one call per app gives its CPU time, memory footprint, disk bytes and energy, counts processes that already exited, and reads root apps without privilege. Polled every 5 s it costs 0.072% CPU; read once a minute and on any 5 s poll with the CPU over 50% busy or memory pressure at warn or critical, 0.014% and 1.5 MB. Those costs leave out mapping each coalition to an app, which reads every process's coalition (`proc_pidinfo`, about 0.25 ms for 1131 processes in `bench`). Stats used 3.3–4.0% and Vorssaint 1.3% on the same Mac. `run.sh` repeats the measurement. |

Details and results: [`docs/design.md`](../docs/design.md#prototypes).
