#!/bin/zsh
# Checks the resource meter against a scripted load from this one shell (M8, exit criterion 2).
# With the Debug app running (scripts/verify/run-app.sh, or a Debug app started with its own
# SOROBAND_DATA_DIR, which this script passes on to `soroband`), it runs for about 100 s:
#   - `yes > /dev/null`, which uses one core;
#   - `dd` writing 1 GiB to a scratch file, fed a mebibyte at a time over about 100 s;
#   - `soroband-alloc`, a program compiled here that fills 512 MiB with bytes that do not
#     compress, and holds it;
# each under `/usr/bin/time -l`, which reports what it used by its own account. Halfway through,
# `soroband top --for 10` must list all three under their own names and show, within 5%, the CPU
# time `yes` used over those seconds (`ps`), the bytes `dd` wrote to its file over them, and
# `soroband-alloc`'s footprint. Once they have ended and the app has written them (up to two
# minutes), `soroband apps --by cpu` must show, against what each used by its own account and
# within 5%: `yes`'s CPU time, the bytes `dd` wrote, and `soroband-alloc`'s average footprint (its
# peak footprint, held all along). The app's stored rows from before the load are subtracted.
#
# It loads the CPU and the disk, so it runs under the measurement lock:
#   scripts/verify/measure-lock.py resources scripts/verify/resources.sh
set -euo pipefail

root=${0:A:h:h:h}
soroband=$root/core/target/debug/soroband
cargo build --quiet --manifest-path $root/core/Cargo.toml -p soroband-cli
seconds=${SOROBAND_LOAD_SECONDS:-100}
work=$(mktemp -d -t soroband-resources)
# The load's `time` processes; on any exit their commands are stopped, so a failed check leaves
# nothing spinning.
loads=()
cleanup() {
  local p
  for p in $loads; do pkill -P $p 2>/dev/null; kill $p 2>/dev/null; done
  rm -rf $work
}
trap cleanup EXIT

cat >$work/alloc.c <<'EOF'
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    size_t size = 512u << 20;
    char *p = malloc(size);
    if (!p) return 1;
    /* Bytes that do not compress, so memory pressure cannot shrink the footprint. */
    unsigned x = 2463534242u;
    for (size_t i = 0; i < size; i++) {
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        p[i] = (char)x;
    }
    sleep((unsigned)atoi(argv[1]));
    return 0;
}
EOF
cc -O0 -o $work/soroband-alloc $work/alloc.c

apps() { $soroband apps --by cpu --json }
before=$(apps)

# Each command's own account: user and system seconds, and its peak footprint in bytes.
cpu_of() { awk '/ real / { print ($3 + $5) * 1e9 }' $1 }
footprint_of() { awk '/peak memory footprint/ { print $1 }' $1 }

/usr/bin/time -l /usr/bin/yes >/dev/null 2>$work/yes.time &
yes_time=$!
loads+=($yes_time)
/usr/bin/time -l $work/soroband-alloc $seconds 2>$work/alloc.time &
alloc_time=$!
loads+=($alloc_time)
# A mebibyte every interval, so dd writes 1 GiB over the whole run.
pace=$(( seconds / 1024.0 ))
( for _ in {1..1024}; do head -c 1048576 /dev/zero; sleep $pace; done ) |
  /usr/bin/time -l /bin/dd of=$work/scratch bs=1m 2>$work/dd.time &
dd_time=$!
loads+=($dd_time)

# CPU seconds a process has used, from ps's [[hh:]mm:]ss.cc.
cpu_seconds() {
  local parts=(${(s.:.)$(ps -o cputime= -p $1 | tr -d ' ')}) total=0 part
  for part in $parts; do total=$(( total * 60 + part )); done
  print $total
}

sleep $(( seconds / 2 ))
# Over the same 10 s as `top`: what `yes` used by its own account, and what `dd` wrote.
yes_pid=$(pgrep -P $yes_time yes)
yes_before=$(cpu_seconds $yes_pid)
dd_before=$(stat -f %z $work/scratch)
top=$($soroband top --for 10 --json)
yes_during=$(( $(cpu_seconds $yes_pid) - yes_before ))
dd_during=$(( $(stat -f %z $work/scratch) - dd_before ))
for name in yes dd soroband-alloc; do
  jq -e --arg n $name '.apps | any(.name == $n)' <<<$top >/dev/null ||
    { print -u2 "resources.sh: soroband top does not list $name"; exit 1; }
done
top_of() { jq --arg n $1 --arg f $2 '[.apps[] | select(.name == $n) | .[$f]] | add // 0' <<<$top }
print "top: source $(jq -r .source <<<$top), over $(jq .seconds <<<$top) s"

sleep $(( seconds / 2 ))
# `yes` runs until stopped; `time` stays to report it.
kill $(pgrep -P $yes_time yes)
wait $yes_time || true
wait $alloc_time || { print -u2 "resources.sh: soroband-alloc failed"; exit 1; }
wait $dd_time || { print -u2 "resources.sh: dd failed"; exit 1; }
written=$(stat -f %z $work/scratch)
(( written == 1 << 30 )) || { print -u2 "resources.sh: dd wrote $written bytes, not 1 GiB"; exit 1; }

# The app reads once a minute and writes once a minute: two minutes covers both.
sleep 125
after=$(apps)
grown() {
  jq -n --argjson a $after --argjson b $before --arg n $1 --arg f $2 '
    ([$a.apps[] | select(.name == $n) | .[$f]] | add // 0) -
    ([$b.apps[] | select(.name == $n) | .[$f]] | add // 0)'
}
latest() {
  jq --arg n $1 --arg f $2 '[.apps[] | select(.name == $n) | .[$f]] | max // 0' <<<$after
}

failed=0
check() {
  local what=$1 got=$2 want=$3
  local ratio=$(( got * 1.0 / want ))
  printf '%-34s %16.0f against %16.0f  (%.3f)\n' $what $got $want $ratio
  (( ratio >= 0.95 && ratio <= 1.05 )) || failed=1
}
check "yes CPU time (ns)" $(grown yes cpu_ns) $(cpu_of $work/yes.time)
check "dd bytes written" $(grown dd disk_written) $written
check "soroband-alloc footprint (bytes)" $(latest soroband-alloc footprint) $(footprint_of $work/alloc.time)
check "top: yes CPU time (ns)" $(top_of yes cpu_ns) $(( yes_during * 1e9 ))
check "top: dd bytes written" $(top_of dd disk_written) $dd_during
check "top: soroband-alloc footprint (bytes)" $(top_of soroband-alloc footprint) $(footprint_of $work/alloc.time)
(( failed == 0 )) || { print -u2 "resources.sh: a resource is off by more than 5%"; exit 1; }
print "resources.sh: passed"
