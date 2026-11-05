# prototypes

Throwaway code that settled the design. Not built, tested or shipped; kept as a reference for the product code in `app/` and `core/`.

| Prototype | What it answered |
| --- | --- |
| `meter-probe` | Can we count per-app internet bytes from the kernel statistics socket ourselves, accurately and cheaply? Yes: 0.035–0.058% CPU, 2 MB. |
| `nstat-probe` | The same through Apple's private `NetworkStatistics.framework`, for comparison: 0.31% CPU, 7.8 MB. |
| `ui-spike` | The look and feel of the menu bar item, popover, history window, settings and Dynamic Island moments, on fake data. |
| `island-spike` | Where does the island run, and drawn with what? In the menu bar process, with AppKit: an AppKit agent grew 3.8–4.3 MB after 30 moments with the island in Core Animation, 5.5–5.7 MB with the ui-spike's SwiftUI view, both at 0.001% CPU at rest; screenshots differ in under 0.15% of pixels and recordings match frame by frame. `run.sh` repeats the measurement; `--record` films a cycle. |
| `popover-spike` | Does option C's popover keep less memory after closing in AppKit than in SwiftUI? A little: after 20 open/close cycles, 20.4 MB in AppKit, 23.7 MB in SwiftUI, 29.6 MB in SwiftUI with Swift Charts, from 9.4 MB at launch (an empty popover: 10.8 MB). The cost is paid at the first open and does not grow; `malloc_zone_pressure_relief` returns none of it. `run.sh` repeats the measurement. |

Details and results: [`docs/design.md`](../docs/design.md#prototypes).
