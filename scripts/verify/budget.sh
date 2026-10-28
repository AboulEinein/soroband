#!/bin/zsh
# Samples a running Soroband for <minutes> and checks it against the budget in docs/design.md:
# average CPU ≤ 0.1% and memory footprint ≤ 25 MB. Exits non-zero when over budget.
#
# Usage: scripts/verify/budget.sh <minutes> [pid]
#   pid: defaults to the only running process named Soroband
#   MEMORY_BUDGET_MB: memory budget in MB (default 25; the engine alone, `soroband live`, has 5)
set -euo pipefail
zmodload zsh/datetime  # EPOCHREALTIME

cpu_budget=0.1   # percent of one core
memory_budget=${MEMORY_BUDGET_MB:-25} # MB, phys_footprint

minutes=${1:?usage: budget.sh <minutes> [pid]}
pid=${2:-}
if [[ -z $pid ]]; then
  pids=($(pgrep -x Soroband || true))
  (( ${#pids} == 1 )) || { print -u2 "budget.sh: expected one Soroband process, found ${#pids}; pass a pid"; exit 2; }
  pid=$pids[1]
fi

# Seconds of CPU time used so far, from ps's [[hh:]mm:]ss.cc.
cpu_seconds() {
  local parts=(${(s.:.)$(ps -o cputime= -p $pid | tr -d ' ')})
  local seconds=0 part
  for part in $parts; do seconds=$(( seconds * 60 + part )); done
  print $seconds
}

footprint_mb() {
  footprint -p $pid | sed -nE 's/.*Footprint: ([0-9.]+) (KB|MB|GB).*/\1 \2/p' |
    awk '{ v = $1; if ($2 == "KB") v /= 1024; if ($2 == "GB") v *= 1024; printf "%.1f", v }'
}

print "Sampling pid $pid ($(ps -o comm= -p $pid)) for $minutes min"
start_cpu=$(cpu_seconds)
start_time=$EPOCHREALTIME
peak=0
for (( i = 0; i < minutes * 6; i++ )); do
  sleep 10
  kill -0 $pid 2>/dev/null || { print -u2 "budget.sh: pid $pid exited"; exit 1; }
  now=$(footprint_mb)
  (( now > peak )) && peak=$now
done
cpu_percent=$(( (($(cpu_seconds) - start_cpu) / ($EPOCHREALTIME - start_time)) * 100 ))

printf 'CPU:    %.3f%% average (budget %s%%)\n' $cpu_percent $cpu_budget
printf 'Memory: %.1f MB peak footprint (budget %s MB)\n' $peak $memory_budget
over=0
(( cpu_percent > cpu_budget )) && { print "CPU over budget"; over=1; }
(( peak > memory_budget )) && { print "Memory over budget"; over=1; }
exit $over
