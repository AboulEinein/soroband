#!/bin/zsh
# Builds a Release of Soroband for this Mac, signs it, installs Soroband.app into /Applications and
# the soroband command into ~/.local/bin, and launches the app. Run it again to update.
#
# Usage: scripts/install.sh [--adhoc] [--replace]
#   By default the app is signed with "Soroband Local Signing", a self-signed certificate this
#   script creates once in its own keychain. The signature then stays the same across builds,
#   so macOS keeps the app's Location permission after an update.
#   --adhoc: sign ad hoc instead; the signature changes with every build.
#   --replace: replace an installed Soroband without a terminal to confirm in. The installed app
#   is the user's own copy, so an agent passes this only when the user asked for the update.
set -euo pipefail

root=${0:A:h:h}
app=/Applications/Soroband.app
bin=$HOME/.local/bin
identity="Soroband Local Signing"
keychain=$HOME/Library/Keychains/soroband-signing.keychain-db
keychain_service="Soroband signing keychain"

fail() { print -u2 "install.sh: $1"; exit 1; }

adhoc=0 replace=0
for arg in "$@"; do
  case $arg in
    --adhoc) adhoc=1 ;;
    --replace) replace=1 ;;
    *) fail "unknown option $arg; usage: scripts/install.sh [--adhoc] [--replace]" ;;
  esac
done

# The installed app is the user's own copy, often running while agents develop in a worktree.
# Replacing it is confirmed in a terminal, or asked for with --replace.
if [[ -e $app ]] && (( ! replace )); then
  [[ -t 0 ]] || fail "$app is already installed, and replacing it quits the running copy. Run this in a terminal to confirm, or pass --replace if the user asked for the update."
  read -q "?Replace the installed $app (it quits if running)? [y/N] " || { print; fail "nothing was changed."; }
  print
fi

# Requirements.
(( ${$(sw_vers -productVersion)%%.*} >= 14 )) || fail "Soroband needs macOS 14 or later."
xcodebuild -version >/dev/null 2>&1 ||
  fail "Xcode is required (the Command Line Tools alone are not enough). Install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app"
command -v cargo >/dev/null || fail "Rust is required. Install it from https://rustup.rs or with: brew install rust"

$root/scripts/build.sh --host
built=$root/build/DerivedData/Build/Products/Release/Soroband.app
cli=$root/core/target/release/soroband

# Returns once the signing keychain is unlocked and holds the identity, creating both when they are
# missing. The keychain's random password is kept in the login keychain, so no prompt appears.
# An existing keychain is replaced only when it holds no identity (a failed earlier run) or its
# password item is gone: a new certificate changes the signature, and macOS then drops the app's
# Location permission.
ensure_identity() {
  if [[ -f $keychain ]]; then
    local password found=0
    password=$(security find-generic-password -s $keychain_service -a $USER -w 2>/dev/null) || found=$?
    if (( found == 0 )); then
      security unlock-keychain -p $password $keychain ||
        fail "cannot unlock $keychain with the password stored in the login keychain"
      security find-identity -p codesigning $keychain | grep -qF "\"$identity\"" && return
    elif (( found != 44 )); then  # 44: no such item
      fail "cannot read the password for $keychain from the login keychain (security exited $found); unlock the login keychain and run again"
    fi
    security delete-keychain $keychain
  fi

  print "Creating the \"$identity\" certificate in $keychain"
  local password=$(openssl rand -hex 24)
  security add-generic-password -U -s $keychain_service -a $USER -w $password
  security create-keychain -p $password $keychain
  security set-keychain-settings $keychain  # no automatic locking

  local tmp=$(mktemp -d)
  cat > $tmp/cert.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Soroband Local Signing
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config $tmp/cert.cnf \
    -keyout $tmp/key.pem -out $tmp/cert.pem 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey $tmp/key.pem -in $tmp/cert.pem \
    -out $tmp/identity.p12 -passout pass:soroband
  security unlock-keychain -p $password $keychain
  security import $tmp/identity.p12 -k $keychain -P soroband -T /usr/bin/codesign >/dev/null
  # Lets codesign use the key without asking.
  security set-key-partition-list -S apple-tool:,apple: -s -k $password $keychain >/dev/null
  rm -rf $tmp
  security find-identity -p codesigning $keychain | grep -qF "\"$identity\"" ||
    fail "could not create the \"$identity\" identity in $keychain"
}

if (( adhoc )); then
  codesign --force --sign - $built
  codesign --force --sign - $cli
else
  ensure_identity
  codesign --force --sign $identity --keychain $keychain $built
  codesign --force --sign $identity --keychain $keychain $cli
fi

# Stop the installed app, if it is running, before replacing it.
for pid in $(pgrep -f "^$app/Contents/MacOS/Soroband\$" || true); do
  kill $pid
  while kill -0 $pid 2>/dev/null; do sleep 0.2; done
done

rm -rf $app
ditto $built $app
mkdir -p $bin
install -m 755 $cli $bin/soroband

open $app
for _ in {1..50}; do
  pid=$(pgrep -f "^$app/Contents/MacOS/Soroband\$" || true)
  [[ -n $pid ]] && break
  sleep 0.2
done
[[ -n $pid ]] || fail "Soroband did not start; see Console.app for crash reports."

print
print "Soroband $($bin/soroband version | cut -d' ' -f2) is installed and running (pid $pid)."
print "  App:     $app ($(codesign -dvv $app 2>&1 | sed -nE 's/^Authority=(.*)/signed by \1/p;s/^Signature=adhoc/signed ad hoc/p'))"
print "  Command: $bin/soroband"
[[ :$PATH: == *:$bin:* ]] || print "  Add $bin to your PATH to run soroband from any directory."
