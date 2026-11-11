# Configuring Soroband: instructions for coding agents

Soroband keeps its settings in `~/Library/Application Support/Soroband/settings.json`. Change them with the `soroband` command, not by editing the file: the command checks each value against the setting's type and range, writes the file atomically, and tells the running app, which applies the change at once without a restart.

## Commands

```sh
soroband config list                  # every setting: value, type, range, default, description
soroband config list --json           # the same as a JSON array
soroband config get reset_hour        # prints the value alone, for scripts
soroband config get reset_hour --json # the value with its schema
soroband config set reset_hour 4      # prints "reset_hour = 4"
```

`soroband config list --json` is the authority on which settings exist. Each entry has `key`, `type`, `default`, `value`, `is_default`, `description`, and `problem` when the file holds a value Soroband cannot use (it then uses the default and says why). An `integer` setting also has `min` and `max`; a `choice` setting has `options`, the words it accepts; a `list` setting has `options` and `max`, how many of them it takes; a `names` setting has `max` and takes any names without a comma.

Exit status: 0 on success; 2 for an unknown key or a value outside the setting's type or range (nothing is saved); 1 when the settings file cannot be read or written. An unreadable `settings.json` is never overwritten: the command reports it, and you should show the user the error and ask before deleting or fixing the file.

## Settings

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `reset_hour` | integer 0–23 | 0 | Hour of the day, local time, when "today" starts again. History is not affected: changing it only moves the start of today. |
| `resource_minutes_days` | integer 1–90 | 7 | Days the minute-by-minute record of the system gauges and the busiest apps is kept. Hourly resource usage is kept forever. |
| `menu_bar_scope` | choice: `network`, `all` | `network` | Whose usage today the menu bar item counts: the current network's or every network's. |
| `menu_bar_readings` | list: up to 4 of `total`, `download`, `upload`, `speed_down`, `speed_up`, separated by commas, or `none` | `total` | What the menu bar item shows beside its icon, in order: today's total, download or upload, or the live download or upload speed. `none` leaves the icon alone. Example: `soroband config set menu_bar_readings download,upload`. |
| `menu_bar_style` | choice: `stacked`, `labeled`, `inline` | `stacked` | How the readings are drawn: in pairs, the first on top, in a smaller size; each under a small caption; or on one line. |
| `menu_bar_icon` | choice: `network`, `soroband` | `network` | The menu bar item's icon: the current network's kind (Wi‑Fi, hotspot, Ethernet), or the Soroband glyph on every network. While counting has stopped it is a warning sign either way. |
| `appearance` | choice: `system`, `light`, `dark` | `system` | Whether Soroband's windows (the popover, Settings, History, the Welcome window) are light or dark: as macOS is, or always light or dark. The island at the notch stays dark. |
| `accent` | choice: `system`, `coral`, `amber`, `emerald`, `teal`, `sky`, `indigo`, `plum`, `rose` | `system` | The color of selections and highlights in Soroband's windows: macOS's accent color, or one of the colors of Soroband's icons. |
| `app_icon` | choice: `graphite`, `indigo`, `plum`, `light`, `hairline-coral`, `hairline-indigo`, `hairline-teal`, `hairline-emerald`, `hairline-amber`, `hairline-rose`, `hairline-sky`, `hairline-graphite`, `hairline-paper` | `graphite` | Soroband's icon in the Dock, in Finder and in Settings › About. Finder shows it only when this account can change the app (`/Applications/Soroband.app` installed by another user keeps the default there); the icon is written into the app as a custom icon, which `codesign --verify --strict` then reports as unsealed content. Example: `soroband config set app_icon hairline-teal`. |
| `island` | choice: `on`, `off` | `off` | Whether the island at the notch shows moments; off makes Soroband a plain menu bar app. |
| `island_style` | choice: `seamless`, `clear` | `seamless` | How the island opens: over the menu bar beside the notch, or notch-wide in the menu bar and wider only below it. |
| `island_moments` | list: any of `peek`, `joined`, `left`, `hotspot`, `hog`, `background`, `transfer`, `recap`, or `none` | all but `recap` | The moments the island shows. |
| `island_hog_mb`, `island_hog_minutes` | integer 1–100000, 1–60 | 100, 5 | A data hog: one app using more than this many megabytes within this many minutes. |
| `island_background_mb` | integer 1–100000 | 50 | Background activity: an app not in front using more than this within `island_hog_minutes`. |
| `island_transfer_mb` | integer 1–100000 | 50 | A large transfer shows once it passes this many megabytes. |
| `island_pause` | choice: `on`, `off` | `on` | Whether a data hog on a hotspot offers Pause until off hotspot, which quits the app and opens it again on the next network that is not a hotspot. |
| `island_full_screen` | choice: `hide`, `alerts`, `all` | `alerts` | What the island shows while an app is full screen: nothing, the data hog and background activity only, or every moment. |
| `island_displays` | choice: `builtin`, `all` | `builtin` | The displays the island shows on. |
| `island_notifications` | choice: `on`, `off` | `on` | Whether data hog and background activity become notifications while the island is off. |
| `island_ignored_apps` | names: app ids separated by commas, or `none` | `none` | Apps that raise no moment, by the id `soroband apps --json` prints (`/Applications/Music.app`, `/usr/bin/curl`, `macOS & Services`). |

The app's Settings window changes the same settings, with the same checks. Launch at login is not a setting here: macOS keeps it (System Settings › General › Login Items), and the app's Settings window turns it on and off.

## Checking usage

The same command reads the usage the app records:

```sh
soroband today --json                  # today per network: apps' bytes and what crossed the network, less local-network traffic
soroband apps --network Home --json    # today's apps on one network (by id, or by name in any case)
soroband apps --json                   # today's apps on all networks
```

`--network` takes a network's id or its name. A value that is some network's id selects that network, even when another network is named the same, so pass the other network's id to pick it.

`rx` is bytes received, `tx` bytes sent. In `soroband today`, `interfaces` is what crossed the network less local-network traffic (Time Machine, AirPlay, a NAS) and `apps` is the part credited to apps; the difference is packet headers, acknowledgements and system traffic. The app writes to its database once a minute and whenever the network changes, so these commands can be up to a minute behind the menu bar.

## Before changing a setting

Tell the user what you will change and why, then run `soroband config set`. Confirm with `soroband config get <key>`.
