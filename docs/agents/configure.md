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

`soroband config list --json` is the authority on which settings exist. Each entry has `key`, `type`, `default`, `value`, `is_default`, `description`, and `problem` when the file holds a value Soroband cannot use (it then uses the default and says why). An `integer` setting also has `min` and `max`; a `choice` setting has `options`, the words it accepts.

Exit status: 0 on success; 2 for an unknown key or a value outside the setting's type or range (nothing is saved); 1 when the settings file cannot be read or written. An unreadable `settings.json` is never overwritten: the command reports it, and you should show the user the error and ask before deleting or fixing the file.

## Settings

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `reset_hour` | integer 0–23 | 0 | Hour of the day, local time, when "today" starts again. History is not affected: changing it only moves the start of today. |
| `menu_bar_scope` | choice: `network`, `all` | `network` | Whose usage today the menu bar item counts: the current network's or every network's. |
| `menu_bar_top` | choice: `total`, `download`, `upload`, `speed`, `speed_down`, `speed_up`, `none` | `total` | The menu bar item's first line: today's total, download or upload, the live speed (both directions, download or upload), or nothing. |
| `menu_bar_bottom` | the same as `menu_bar_top` | `none` | The second line, stacked under the first in a smaller size. With both `none` the item is its icon alone. |

The app's Settings window changes the same settings, with the same checks. Launch at login is not a setting here: macOS keeps it (System Settings › General › Login Items), and the app's Settings window turns it on and off.

## Checking usage

The same command reads the usage the app records:

```sh
soroband today --json                  # today per network: apps' bytes and what crossed the network
soroband apps --network Home --json    # today's apps on one network (by name, any case, or by id)
soroband apps --json                   # today's apps on all networks
```

`rx` is bytes received, `tx` bytes sent. In `soroband today`, `interfaces` is what crossed the network and `apps` is the part credited to apps; the difference is packet headers, acknowledgements and system traffic. The app writes to its database once a minute and whenever the network changes, so these commands can be up to a minute behind the menu bar.

## Before changing a setting

Tell the user what you will change and why, then run `soroband config set`. Confirm with `soroband config get <key>`.
