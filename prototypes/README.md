# prototypes

Throwaway code that settled the design. Not built, tested or shipped; kept as a reference for the product code in `app/` and `core/`.

| Prototype | What it answered |
| --- | --- |
| `meter-probe` | Can we count per-app internet bytes from the kernel statistics socket ourselves, accurately and cheaply? Yes: 0.035–0.058% CPU, 2 MB. |
| `nstat-probe` | The same through Apple's private `NetworkStatistics.framework`, for comparison: 0.31% CPU, 7.8 MB. |
| `ui-spike` | The look and feel of the menu bar item, popover, history window, settings and Dynamic Island moments, on fake data. |

Details and results: [`docs/design.md`](../docs/design.md#prototypes).
