# Install Soroband (for coding agents)

You are installing Soroband, a macOS menu bar app that meters internet usage per app and per network, on the user's Mac. Follow these steps in order. Run commands yourself; ask the user only where a step says so.

Soroband builds from source: there is no release download yet.

## 1. Check the requirements

| Requirement | Check | If it fails |
| --- | --- | --- |
| macOS 14 or later | `sw_vers -productVersion` | Stop: Soroband cannot run on this Mac. |
| Xcode (not only the Command Line Tools) | `xcodebuild -version` prints a version | Ask the user to install Xcode from the App Store, open it once, then run `sudo xcode-select -s /Applications/Xcode.app` (the user types their password). |
| Rust | `cargo --version` | Install Rust: `brew install rust` if Homebrew is present (`command -v brew`), otherwise ask the user to run the installer from https://rustup.rs. |
| Git | `git --version` | Accept the prompt macOS shows to install the Command Line Tools. |
| Network access | | The first build downloads Rust crates and the `cbindgen` tool. |

## 2. Get the source

If the user is not already in a clone of `https://github.com/AboulEinein/soroband`, clone it into a directory the user agrees to (default `~/Developer/soroband`) and `cd` into it. If a clone exists, update it with `git pull`.

## 3. Run the install script

From the root of the clone:

```sh
scripts/install.sh
```

It takes a few minutes on the first run. It:

- builds the core (Rust) and the app (Xcode) for this Mac;
- signs the app with "Soroband Local Signing", a self-signed certificate it creates once in its own keychain (`~/Library/Keychains/soroband-signing.keychain-db`), so macOS keeps the app's permissions across updates. Creating it shows no prompt; the first run prints `Creating the "Soroband Local Signing" certificate`;
- installs `Soroband.app` into `/Applications` and the `soroband` command into `~/.local/bin`;
- launches the app.

The script ends with `Soroband <version> is installed and running (pid <pid>)`. If it fails, read the error: each requirement failure names its fix. Do not work around a failure by editing the script.

To update an existing install, run `scripts/install.sh --replace`, and only when the user asked for the update: it quits and replaces the user's running copy. Without `--replace`, the script stops before building when Soroband is already installed and there is no terminal to confirm in.

## 4. Verify

```sh
pgrep -fl '^/Applications/Soroband.app/Contents/MacOS/Soroband$'   # prints the running app
~/.local/bin/soroband version                                    # prints "soroband <version>"
```

If `~/.local/bin` is not on the user's `PATH` (the script says so), offer to add `export PATH="$HOME/.local/bin:$PATH"` to their shell profile.

Soroband has no Dock icon and no window: it lives in the menu bar as "Soroband <version>". Ask the user to confirm they see it. If they do not, the menu bar is probably full and the item is hidden behind the notch or by a menu bar manager; quitting another menu bar app or hiding items in it makes room.

## 5. Location permission

macOS reveals the Wi‑Fi network name only to apps with Location access, and Soroband uses it to book usage to the right network. It never stores or sends your location.

Ask the user to:

1. Click **Soroband** in the menu bar and choose **Allow Location Access…**.
2. Click **Allow** in the macOS prompt.
3. Check that the menu now reads **Location Access: Allowed**.

If the menu reads **Location Access: Off**, the user denied it earlier or Location Services is off: choosing that item opens System Settings › Privacy & Security › Location Services, where the user turns on Location Services and Soroband.

## Done

Tell the user Soroband is installed, where the app and command are, and that running `scripts/install.sh` again from the clone updates it.
