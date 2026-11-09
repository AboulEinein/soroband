# Install Soroband (for coding agents)

You are installing Soroband, a macOS menu bar app that meters internet usage per app and per network, on the user's Mac. Follow these steps in order. Run commands yourself; ask the user only where a step says so.

There are two routes:

- **Release** (the default): download `Soroband.dmg` from the latest GitHub release, check its checksum and copy the app to `/Applications`. Needs nothing but macOS. The app is signed ad hoc, not notarized by Apple.
- **From source:** clone the repository and run `scripts/install.sh`, which builds and signs the app on this Mac. Needs Xcode and Rust, and takes a few minutes. macOS never blocks an app built on the same Mac, and it keeps the app's Location permission across updates.

## 1. Check the Mac

| Check | Command | If it fails |
| --- | --- | --- |
| macOS 14 or later | `sw_vers -productVersion` | Stop: Soroband cannot run on this Mac. |
| Is Soroband installed already? | `ls -d /Applications/Soroband.app` | If it is, ask the user whether they want it updated, and go to [Updating](#updating) instead. |

Per-app counting needs macOS 27; on macOS 14 to 26 Soroband counts each network's total only. Tell the user before installing on such a Mac.

Ask the user which route they want, recommending the release unless they prefer to build it themselves. Then follow section 2 or section 3.

## 2. Install the release

Work in a new temporary directory. The blocks below use `$dir`: run them in one shell session, or note the path and set `dir` again in each (every path below is absolute).

```sh
dir=$(mktemp -d)
curl -fL -o "$dir/Soroband.dmg" https://github.com/AboulEinein/soroband/releases/latest/download/Soroband.dmg
curl -fL -o "$dir/Soroband.dmg.sha256" https://github.com/AboulEinein/soroband/releases/latest/download/Soroband.dmg.sha256
(cd "$dir" && shasum -a 256 -c Soroband.dmg.sha256)
```

The last command must print `Soroband.dmg: OK`. If it prints anything else, stop: delete the directory and tell the user the download did not match its checksum.

Copy the app into `/Applications`:

```sh
hdiutil attach -nobrowse -readonly -mountpoint "$dir/mount" "$dir/Soroband.dmg"
ditto "$dir/mount/Soroband.app" /Applications/Soroband.app
```

If `ditto` fails with a permission error, the user's account cannot write to `/Applications`. Leave the disk image mounted and ask the user to drag `Soroband.app` from it (`open "$dir/mount"` shows it in the Finder) into Applications, which asks for an administrator's password. Go on once `/Applications/Soroband.app` exists.

Then unmount the disk image, link the `soroband` command into `~/.local/bin`, and clean up:

```sh
hdiutil detach "$dir/mount"
mkdir -p ~/.local/bin
ln -sf /Applications/Soroband.app/Contents/Helpers/soroband ~/.local/bin/soroband
rm -rf "$dir"
```

### The quarantine flag

A file downloaded with `curl` carries no quarantine flag, so macOS opens the app without asking. A disk image the user downloaded in a browser does, and macOS then blocks the first launch because Apple has not notarized the app. Check:

```sh
xattr -p com.apple.quarantine /Applications/Soroband.app
```

If it prints `No such xattr`, go on to section 4. If it prints a value, tell the user that macOS will block the first launch until they approve it, and offer both ways:

- **With the user's consent,** clear the flag yourself: `xattr -dr com.apple.quarantine /Applications/Soroband.app`. This skips the check macOS makes on apps from the internet, for this app only. Never run it without a yes.
- **Or the user approves it:** after the first launch (section 4) is blocked, the user opens **System Settings › Privacy & Security**, clicks **Open Anyway** next to "Soroband", and confirms with their password.

Then go to section 4.

## 3. Build from source

### Requirements

| Requirement | Check | If it fails |
| --- | --- | --- |
| Xcode (not only the Command Line Tools) | `xcodebuild -version` prints a version | Ask the user to install Xcode from the App Store, open it once, then run `sudo xcode-select -s /Applications/Xcode.app` (the user types their password). |
| Rust | `cargo --version` | Install Rust: `brew install rust` if Homebrew is present (`command -v brew`), otherwise ask the user to run the installer from https://rustup.rs. |
| Git | `git --version` | Accept the prompt macOS shows to install the Command Line Tools. |
| Network access | | The first build downloads Rust crates and the `cbindgen` tool. |

### Get the source

If the user is not already in a clone of `https://github.com/AboulEinein/soroband`, clone it into a directory the user agrees to (default `~/Developer/soroband`) and `cd` into it. If a clone exists, update it with `git pull`.

### Run the install script

From the root of the clone:

```sh
scripts/install.sh
```

It takes a few minutes on the first run. It:

- builds the core (Rust) and the app (Xcode) for this Mac;
- signs the app with "Soroband Local Signing", a self-signed certificate it creates once in its own keychain (`~/Library/Keychains/soroband-signing.keychain-db`), so macOS keeps the app's permissions across updates. Creating it shows no prompt; the first run prints `Creating the "Soroband Local Signing" certificate`;
- installs `Soroband.app` into `/Applications` and the `soroband` command into `~/.local/bin`;
- launches the app.

The script ends with `Soroband <version> (<build>) · <commit> <branch> is installed and running (pid <pid>)`, the build stamp naming the commit it was built from. If it fails, read the error: each requirement failure names its fix. Do not work around a failure by editing the script. Then go to section 4; the app is already running.

## 4. Open and verify

```sh
open /Applications/Soroband.app                                     # the release route; install.sh already opened it
pgrep -fl '^/Applications/Soroband.app/Contents/MacOS/Soroband$'   # prints the running app
~/.local/bin/soroband version                                       # prints "soroband <version> (<build>) · <commit> <branch>"
```

If `pgrep` prints nothing after the release route, macOS blocked the launch: ask the user to click **Open Anyway** as in section 2, then run `open` again.

If `~/.local/bin` is not on the user's `PATH` (`echo $PATH`), offer to add `export PATH="$HOME/.local/bin:$PATH"` to their shell profile.

Soroband has no Dock icon: it lives in the menu bar as a network icon with today's usage. Ask the user to confirm they see it. If they do not, the menu bar is probably full and the item is hidden behind the notch or by a menu bar manager; quitting another menu bar app or hiding items in it makes room.

## 5. Location permission

macOS reveals the Wi‑Fi network name only to apps with Location access, and Soroband uses it to book usage to the right network. It never stores or sends your location.

Ask the user to:

1. Click **Allow Location Access** in the **Welcome to Soroband** window, which opens at the first launch. If it does not open, click the Soroband item in the menu bar, click the gear button at the bottom of the popover, and click **Allow…** in Settings › General › Wi‑Fi names.
2. Click **Allow** in the macOS prompt.
3. Check that Settings › General › Wi‑Fi names reads **Allowed: Wi‑Fi networks show their names**.

If it reads **Not allowed: Wi‑Fi networks show as “Wi‑Fi”** with an **Open Location Settings…** button, the user denied it earlier or Location Services is off: that button opens System Settings › Privacy & Security › Location Services, where the user turns on Location Services and Soroband.

## Updating

Update only when the user asks: it quits and replaces the user's running copy.

- **Installed from a release** (`/Applications/Soroband.app/Contents/Helpers/soroband` exists; a source build has no command inside the app): run `/Applications/Soroband.app/Contents/Helpers/soroband update`. It downloads the newest release, checks its checksum, quits Soroband, replaces the app and opens it again; `soroband update --check` only says whether there is a newer one. A downloaded update carries no quarantine flag, so no Open Anyway is needed. Check the release notes for whether macOS asks for Location access again.
- **Built from source:** from the clone, `git pull && scripts/install.sh --replace`. Without `--replace`, the script stops before building when Soroband is already installed and there is no terminal to confirm in; in a terminal it asks first, and only the user answers that question. The script cannot tell the user from an agent, so the user's request is what allows `--replace` or a typed yes.

## Done

Tell the user Soroband is installed, where the app and the command are, how to update it (above), and that `soroband config list` shows every setting ([`configure.md`](configure.md) has the details).
