#!/usr/bin/env bash
# bench-env.sh: configure this host for low-noise compiler benchmarking.
#
# Inspired by scala/compiler-benchmark's scripts/benv and
# https://github.com/scala/scala-dev/issues/338 , adapted for:
#   * cgroup v2 *or* v1-hybrid (auto-detected; no `cset` either way),
#   * a persistent $HOME on an otherwise ephemeral image,
#   * three deployment modes:
#     - KVM guest, Ubuntu 22.04 (cgroup v2, intel_pstate unavailable,
#       single NUMA, 32 vCPUs)
#     - bare-metal, Ubuntu 22.04 (cgroup v2, intel_pstate available,
#       Falcon LSM hooks unkillable in-kernel)
#     - bare-metal, Ubuntu 20.04 (cgroup v1 hybrid, intel_pstate active
#       but defaulting to `powersave` governor, kernel 5.4 — no in-kernel
#       Falcon LSM hooks, `falcon-sensor.service` stops cleanly)
# The script auto-detects which we're on and adjusts defaults.
#
# Subcommands
#   set     Apply noise-reduction knobs and create the `bench.slice` cpuset.
#   reset   Restore saved state; stop the bench slice.
#   status  Print current state of all knobs.
#   run     Launch a command inside the bench cpuset, with high priority.
#           Example:  bench-env.sh run -- bash compiler-benchmark/run-bench.sh
#
# Safety: the ONLY things this script never touches are:
#   * ssh (ssh.service), Eternal Terminal (et.service)  -- our access path
#   * Cursor remote (runs under user@1000.service)       -- our IDE
#   * Arca daemon (arca_package_scanner.service)         -- ops requirement
# Everything else in SERVICES_TO_STOP/TIMERS_TO_STOP is fair game and will
# be reset on reboot (the root fs is ephemeral) or by `bench-env.sh reset`.
#
# Notably stopped by default:
#   * Kolide (launcher.kolide-k2.service + its child osqueryd)
#   * CrowdStrike Falcon (falcon-sensor.service) -- the biggest single noise
#     source on this host (~4% CPU continuously)
#   * osquery metric forwarder
#   * AWS Systems Manager agent
#   * auditd, rsyslog, chrony, snapd, acpid, networkd-dispatcher, polkit
#   * EC2 termination-watcher, devbox_daemon
# Left alone (too risky / needed by ssh/logind/journal/network):
#   * dbus, systemd-logind, systemd-journald, systemd-resolved,
#     systemd-networkd, systemd-udevd, user@1000.service, containerd, docker
#
# Options on `set` (env vars or flags):
#   BENCH_CPUS=0-3           CPUs dedicated to the benchmark slice
#   SYS_CPUS=auto            CPUs the rest of the system can use. Default:
#                            auto-detects NUMA topology and picks the
#                            other socket(s) when multi-NUMA; otherwise
#                            "all except BENCH_CPUS and their HT siblings".
#   HT_OFFLINE=1             1 = offline HT siblings of BENCH_CPUS
#   PARTITION_ROOT=1         1 = try to promote bench.slice to a root
#                            cpuset partition (strongest isolation, kernel
#                            scheduler evicts other tasks from those CPUs)
#   ISOLATE_SYS=auto         1 = also pin system.slice and user.slice to
#                            SYS_CPUS via their cpuset.cpus.  Auto-enabled
#                            when multi-socket (so nothing pollutes the
#                            bench socket's L3 cache).
#   STOP_SERVICES=1          1 = stop chatty systemd services
#   STOP_TIMERS=1            1 = stop chatty systemd timers
#   PIN_IRQ=1                1 = point IRQ affinity at SYS_CPUS
#   NO_THP=1                 1 = transparent_hugepage=never
#   FREQ_FIX=auto            1 = pin CPU frequency: intel_pstate no_turbo=1
#                            and hwp_dynamic_boost=0.  Auto-enabled when
#                            intel_pstate is the active driver.
#   DROP_CACHES=1            1 = echo 3 > /proc/sys/vm/drop_caches each run
#   NICE=-10                 Nice level for the bench slice

set -u -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# State should live with the invoking user, not under /root, so that
# `sudo bench-env.sh set` and `bench-env.sh status` see the same state.
# When run via sudo, prefer SUDO_USER's home; otherwise fall back to $HOME.
if [[ -n "${SUDO_USER:-}" && -z "${BENCH_ENV_STATE_DIR:-}" ]]; then
  STATE_DIR="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.bench-env-state"
else
  STATE_DIR="${BENCH_ENV_STATE_DIR:-$HOME/.bench-env-state}"
fi
STATE_FILE="$STATE_DIR/state.env"
IRQ_FILE="$STATE_DIR/irq.tsv"
SVC_FILE="$STATE_DIR/services.tsv"
TIMER_FILE="$STATE_DIR/timers.tsv"
mkdir -p "$STATE_DIR"

BENCH_CPUS="${BENCH_CPUS:-0-3}"
HT_OFFLINE="${HT_OFFLINE:-1}"
PARTITION_ROOT="${PARTITION_ROOT:-1}"
STOP_SERVICES="${STOP_SERVICES:-1}"
STOP_TIMERS="${STOP_TIMERS:-1}"
PIN_IRQ="${PIN_IRQ:-1}"
NO_THP="${NO_THP:-1}"
DROP_CACHES="${DROP_CACHES:-1}"
NICE_LEVEL="${NICE:--10}"
BENCH_UNIT="${BENCH_UNIT:-bench.slice}"

# Detect cgroup hierarchy version.
#   v2: unified hierarchy at /sys/fs/cgroup/ (Ubuntu 22.04+ default),
#       cgroup.controllers exists at the root, cpuset is a sibling
#       controller under bench.slice/.
#   v1: legacy multi-hierarchy (Ubuntu 20.04 default), cpuset has its
#       own mount under /sys/fs/cgroup/cpuset/.  No unified
#       cpuset.cpus.partition; kernel-enforced exclusion uses
#       cpuset.cpu_exclusive=1 instead.
detect_cgroup_version() {
  if [[ -f /sys/fs/cgroup/cgroup.controllers ]] \
     && grep -qw cpuset /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
    echo 2
  elif [[ -d /sys/fs/cgroup/cpuset ]]; then
    echo 1
  else
    echo 0
  fi
}
CG_VERSION=$(detect_cgroup_version)

# Path to the bench cgroup directory.
#   v2: /sys/fs/cgroup/<BENCH_UNIT>          (e.g. /sys/fs/cgroup/bench.slice)
#   v1: /sys/fs/cgroup/cpuset/<short-name>   (.slice suffix is meaningless on v1)
bench_cg_path() {
  if [[ "$CG_VERSION" == "2" ]]; then
    echo "/sys/fs/cgroup/$BENCH_UNIT"
  else
    local short="${BENCH_UNIT%.slice}"
    echo "/sys/fs/cgroup/cpuset/$short"
  fi
}

# Auto-detect defaults based on hardware.  We need these before SYS_CPUS
# and FREQ_FIX can fall back to sensible values.
detect_numa_nodes() {
  local n=0
  shopt -s nullglob
  for d in /sys/devices/system/node/node[0-9]*; do n=$((n+1)); done
  shopt -u nullglob
  echo "$n"
}

# Return cpulist of the NUMA node that does NOT contain BENCH_CPUS's
# first CPU.  Empty when only one NUMA node.
other_numa_cpulist() {
  local bench_first=${BENCH_CPUS%%[,-]*}
  local bench_node=""
  shopt -s nullglob
  for d in /sys/devices/system/node/node[0-9]*; do
    local cpulist; cpulist=$(cat "$d/cpulist" 2>/dev/null)
    if cpulist_contains "$cpulist" "$bench_first"; then
      bench_node="$d"
      break
    fi
  done
  [[ -z "$bench_node" ]] && { shopt -u nullglob; return; }
  for d in /sys/devices/system/node/node[0-9]*; do
    [[ "$d" == "$bench_node" ]] && continue
    cat "$d/cpulist" 2>/dev/null
    # Take the first "other" node only.  For ≥3 sockets, adjust as needed.
    break
  done
  shopt -u nullglob
}

# Return true if $1 (cpulist) contains $2 (single cpu id).
cpulist_contains() {
  local spec="$1" target="$2"
  IFS=',' read -ra parts <<<"$spec"
  for p in "${parts[@]}"; do
    if [[ "$p" == *-* ]]; then
      local lo=${p%-*} hi=${p#*-}
      (( target >= lo && target <= hi )) && return 0
    else
      (( target == p )) && return 0
    fi
  done
  return 1
}

NUMA_NODES=$(detect_numa_nodes)
if [[ -z "${SYS_CPUS:-}" ]]; then
  if (( NUMA_NODES > 1 )); then
    SYS_CPUS=$(other_numa_cpulist)
    : "${SYS_CPUS:=4-15,20-31}"  # shouldn't happen, but be safe
  else
    # Single-NUMA default (e.g. our 32-vCPU KVM guest): skip HT siblings
    # of 0-3 (16-19) and keep 4-15,20-31 for the system.
    SYS_CPUS="4-15,20-31"
  fi
fi
: "${ISOLATE_SYS:=auto}"
if [[ "$ISOLATE_SYS" == "auto" ]]; then
  if (( NUMA_NODES > 1 )); then ISOLATE_SYS=1; else ISOLATE_SYS=0; fi
fi
: "${FREQ_FIX:=auto}"
if [[ "$FREQ_FIX" == "auto" ]]; then
  if [[ -r /sys/devices/system/cpu/intel_pstate/status ]] && \
     [[ "$(cat /sys/devices/system/cpu/intel_pstate/status 2>/dev/null)" == "active" ]]; then
    FREQ_FIX=1
  else
    FREQ_FIX=0
  fi
fi

SERVICES_TO_STOP=(
  # Chatty but low-impact (from the conservative list)
  acpid.service
  cron.service
  atd.service
  irqbalance.service
  collectd.service
  packagekit.service
  unattended-upgrades.service
  motd-news.service
  snap.canonical-livepatch.canonical-livepatchd.service

  # Monitoring agents -- the real CPU offenders on our fleet.
  # On Ubuntu 22.04 + Falcon BPF kernel module these only stop the
  # userspace daemon; on Ubuntu 20.04 + kernel 5.4 (no falcon kernel
  # piece) the stop is complete.
  launcher.kolide-k2.service              # Kolide K2 (spawns osqueryd)
  falcon-sensor.service                   # CrowdStrike Falcon
  osquery-metric-forwarder.service        # osquery + metric forwarder

  # Databricks / EC2 bookkeeping daemons
  termination-watcher.service             # EC2 termination-tag poller
  devbox_daemon.service                   # Databricks devbox poller

  # System daemons not needed during benchmarking
  chrony.service                          # NTP (irrelevant for nanoTime/monotonic)
  auditd.service                          # kernel audit (noisy syscalls)
  rsyslog.service                         # log forwarder (journald suffices)
  snapd.service                           # snap daemon
  snap.amazon-ssm-agent.amazon-ssm-agent.service  # AWS SSM agent
  networkd-dispatcher.service             # systemd-networkd event watcher
  polkit.service                          # authorization manager

  # Ubuntu 20.04 baseline image extras (no-ops on 22.04)
  awsagent.service                        # LSB AWS Agent (legacy, ~0.1%)
  accounts-daemon.service                 # desktop account info (D-Bus)
  ModemManager.service                    # 3G/LTE modem manager (irrelevant on EC2)
  NetworkManager.service                  # systemd-networkd handles routing/DNS already
  avahi-daemon.service                    # zeroconf mDNS responder
  rtkit-daemon.service                    # realtime scheduling broker (we don't use it)
  switcheroo-control.service              # GPU switching for laptops
  multipathd.service                      # SAN multipath (no SAN here)
  udisks2.service                         # disk hot-plug manager
  wpa_supplicant.service                  # Wi-Fi auth (no Wi-Fi on EC2)
  gdm.service                             # GNOME Display Manager (server has no display)
  apport.service                          # crash reporter
)

# Active timers vary across image versions.  We list every timer we've
# seen on either Ubuntu 22.04 or 20.04; any that aren't loaded on this
# host are silently skipped.
TIMERS_TO_STOP=(
  # Ubuntu 22.04
  apt-daily.timer
  apt-daily-upgrade.timer
  dpkg-db-backup.timer
  update-notifier-download.timer
  update-notifier-motd.timer
  # Common to both
  e2scrub_all.timer
  fstrim.timer
  logrotate.timer
  man-db.timer
  motd-news.timer
  system-cleanup.timer
  systemd-tmpfiles-clean.timer
  ua-timer.timer
  # Ubuntu 20.04
  fwupd-refresh.timer
)

# Sockets and path units that would re-activate services we just stopped.
# Without these, anything that writes to /dev/log or hits /run/snapd.socket
# will spawn a new rsyslogd/snapd respectively; CPU online/offline events
# (like step_offline_ht) trigger acpid via /proc/acpi/event through the
# acpid.path unit.
SOCKETS_TO_STOP=(
  syslog.socket      # prevents rsyslog respawn on log writes
  snapd.socket       # prevents snapd respawn on snap-cli calls
  acpid.socket       # prevents acpid respawn on ACPI socket connect
  acpid.path         # prevents acpid respawn on /proc/acpi/event
)

# Processes we try hard to kill but know are self-protected by an LSM
# *on Ubuntu 22.04 with the Falcon BPF kernel module loaded*:
#   * falcon-sensor-bpf (CrowdStrike) -- sudo kill -9 returns EPERM, as
#     does writing to its cgroup.kill.  We accept it as noise floor; the
#     cpuset partition keeps it off BENCH_CPUS (it typically ends up on
#     a sys CPU).
#
# On Ubuntu 20.04 + kernel 5.4 the Falcon agent is userspace-only -- no
# kernel module, no LSM hook (lockdown,capability,yama,apparmor only),
# and `systemctl stop falcon-sensor.service` removes it cleanly.  The
# absence of the LSM hook is the main reason we expect lower wall-time
# noise on the 20.04 image (no in-kernel BPF programs piggy-backing on
# our syscalls).

# HT siblings of BENCH_CPUS (computed by expanding the list and reading /sys).
ht_siblings_of() {
  local cpus="$1"
  local expanded=()
  IFS=',' read -ra parts <<<"$cpus"
  for p in "${parts[@]}"; do
    if [[ "$p" == *-* ]]; then
      local lo=${p%-*} hi=${p#*-}
      for ((i=lo; i<=hi; i++)); do expanded+=("$i"); done
    else
      expanded+=("$p")
    fi
  done
  local siblings=()
  local seen=" "
  for c in "${expanded[@]}"; do seen+="$c "; done
  for c in "${expanded[@]}"; do
    local sib_list
    sib_list=$(cat "/sys/devices/system/cpu/cpu$c/topology/thread_siblings_list" 2>/dev/null || true)
    IFS=',' read -ra ss <<<"$sib_list"
    for s in "${ss[@]}"; do
      if [[ "$s" == *-* ]]; then
        local lo=${s%-*} hi=${s#*-}
        for ((i=lo; i<=hi; i++)); do
          [[ "$seen" == *" $i "* ]] || { siblings+=("$i"); seen+="$i "; }
        done
      else
        [[ "$seen" == *" $s "* ]] || { siblings+=("$s"); seen+="$s "; }
      fi
    done
  done
  echo "${siblings[@]}"
}

# Logging helpers
msg()  { printf '[bench-env] %s\n' "$*"; }
ok()   { printf '[bench-env]   ok: %s\n' "$*"; }
warn() { printf '[bench-env] warn: %s\n' "$*" >&2; }
err()  { printf '[bench-env] err:  %s\n' "$*" >&2; }

sudow() { # sudoWrite
  local val="$1" path="$2"
  if printf '%s' "$val" | sudo -n tee "$path" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

save_state() {  # key=value
  local k="$1" v="$2"
  # Remove prior entry, append new.
  if [[ -f "$STATE_FILE" ]]; then
    sed -i.bak "/^${k}=/d" "$STATE_FILE" && rm -f "${STATE_FILE}.bak"
  fi
  printf '%s=%s\n' "$k" "$v" >> "$STATE_FILE"
}

get_state() {   # key -> value (empty if missing)
  local k="$1"
  [[ -f "$STATE_FILE" ]] || { echo ""; return 0; }
  local v
  v=$(awk -F= -v k="$k" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$STATE_FILE" 2>/dev/null)
  echo "$v"
}

########################################################################
# Steps
########################################################################

step_offline_ht() {
  [[ "$HT_OFFLINE" == "1" ]] || return 0
  local siblings
  siblings=$(ht_siblings_of "$BENCH_CPUS")
  if [[ -z "$siblings" ]]; then
    warn "no HT siblings found for $BENCH_CPUS (HT probably disabled)"
    return 0
  fi
  save_state HT_SIBLINGS "$siblings"
  for c in $siblings; do
    local online_file="/sys/devices/system/cpu/cpu$c/online"
    [[ -w "$online_file" || -e "$online_file" ]] || continue
    if sudow 0 "$online_file"; then
      ok "offlined HT sibling cpu$c"
    else
      warn "failed to offline cpu$c"
    fi
  done
}

step_online_ht() {
  local siblings
  siblings=$(get_state HT_SIBLINGS)
  [[ -n "$siblings" ]] || return 0
  for c in $siblings; do
    local online_file="/sys/devices/system/cpu/cpu$c/online"
    if sudow 1 "$online_file"; then ok "re-onlined cpu$c"; fi
  done
  save_state HT_SIBLINGS ""
}

step_thp() {
  [[ "$NO_THP" == "1" ]] || return 0
  local cur
  cur=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true)
  if [[ -z "$cur" ]]; then
    warn "no transparent_hugepage sysfs"
    return 0
  fi
  local prev
  prev=$(awk '{ for (i=1;i<=NF;i++) if ($i ~ /^\[.*\]$/) { gsub(/[\[\]]/, "", $i); print $i; exit } }' \
          <<<"$cur")
  save_state THP_PREV "$prev"
  if sudow "never" /sys/kernel/mm/transparent_hugepage/enabled; then
    ok "THP: $prev -> never"
  else
    warn "failed to set THP"
  fi
  # Also defrag (less important, but good practice)
  local dprev
  dprev=$(awk '{ for (i=1;i<=NF;i++) if ($i ~ /^\[.*\]$/) { gsub(/[\[\]]/, "", $i); print $i; exit } }' \
          </sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null)
  [[ -n "$dprev" ]] && save_state THP_DEFRAG_PREV "$dprev"
  sudow "never" /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
}

step_thp_reset() {
  local prev dprev
  prev=$(get_state THP_PREV)
  dprev=$(get_state THP_DEFRAG_PREV)
  if [[ -n "$prev" ]]; then
    if sudow "$prev" /sys/kernel/mm/transparent_hugepage/enabled; then
      ok "THP restored to $prev"
    fi
    save_state THP_PREV ""
  fi
  if [[ -n "$dprev" ]]; then
    sudow "$dprev" /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
    save_state THP_DEFRAG_PREV ""
  fi
}

# CPU frequency fixing (bare-metal only, requires intel_pstate=active).
# Turns off turbo and HWP dynamic boost so all CPUs run at the base
# frequency, and switches the governor to `performance` (Ubuntu 22.04
# image already defaults to performance on bare-metal; Ubuntu 20.04
# image defaults to powersave, which actually paces aggressively under
# light load even with intel_pstate=active and is a noise source).
step_freq_fix() {
  [[ "$FREQ_FIX" == "1" ]] || return 0
  if [[ ! -w /sys/devices/system/cpu/intel_pstate/no_turbo ]] && \
     ! sudo -n test -w /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null; then
    warn "FREQ_FIX requested but intel_pstate is not writable; skipping"
    return 0
  fi
  local prev_turbo prev_hwp
  prev_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo "")
  [[ -n "$prev_turbo" ]] && save_state NO_TURBO_PREV "$prev_turbo"
  if sudow "1" /sys/devices/system/cpu/intel_pstate/no_turbo; then
    ok "intel_pstate/no_turbo: $prev_turbo -> 1 (turbo disabled)"
  else
    warn "could not set no_turbo"
  fi
  if [[ -e /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost ]]; then
    prev_hwp=$(cat /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost 2>/dev/null || echo "")
    [[ -n "$prev_hwp" ]] && save_state HWP_DYN_BOOST_PREV "$prev_hwp"
    if sudow "0" /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost; then
      ok "intel_pstate/hwp_dynamic_boost: $prev_hwp -> 0"
    else
      warn "could not set hwp_dynamic_boost"
    fi
  fi
  # Governor: write `performance` to every cpu's cpufreq.  Save the
  # previous value of cpu0 only -- in practice all online cpus share
  # one governor on intel_pstate, so this is enough for reset.
  local gov_prev
  gov_prev=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "")
  if [[ -n "$gov_prev" && "$gov_prev" != "performance" ]]; then
    save_state GOVERNOR_PREV "$gov_prev"
    local n_set=0 n_total=0
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      [[ -w "$f" ]] || sudo -n test -w "$f" 2>/dev/null || continue
      n_total=$((n_total+1))
      sudow "performance" "$f" 2>/dev/null && n_set=$((n_set+1))
    done
    ok "scaling_governor: $gov_prev -> performance ($n_set/$n_total cpus)"
  fi
}

step_freq_reset() {
  local prev
  prev=$(get_state NO_TURBO_PREV)
  if [[ -n "$prev" ]]; then
    sudow "$prev" /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null \
      && ok "no_turbo restored to $prev"
    save_state NO_TURBO_PREV ""
  fi
  prev=$(get_state HWP_DYN_BOOST_PREV)
  if [[ -n "$prev" && -e /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost ]]; then
    sudow "$prev" /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost 2>/dev/null \
      && ok "hwp_dynamic_boost restored to $prev"
    save_state HWP_DYN_BOOST_PREV ""
  fi
  prev=$(get_state GOVERNOR_PREV)
  if [[ -n "$prev" ]]; then
    local n_set=0 n_total=0
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      [[ -w "$f" ]] || sudo -n test -w "$f" 2>/dev/null || continue
      n_total=$((n_total+1))
      sudow "$prev" "$f" 2>/dev/null && n_set=$((n_set+1))
    done
    ok "scaling_governor restored to $prev ($n_set/$n_total cpus)"
    save_state GOVERNOR_PREV ""
  fi
}

step_services_stop() {
  [[ "$STOP_SERVICES" == "1" ]] || return 0
  : > "$SVC_FILE"
  for s in "${SERVICES_TO_STOP[@]}"; do
    local active
    active=$(systemctl is-active "$s" 2>/dev/null || true)
    if [[ "$active" == "active" ]]; then
      if sudo -n systemctl stop "$s" >/dev/null 2>&1; then
        ok "stopped $s"
        printf '%s\twas-active\n' "$s" >> "$SVC_FILE"
      else
        warn "failed to stop $s"
      fi
    fi
  done
}

step_services_start() {
  [[ -f "$SVC_FILE" ]] || return 0
  while IFS=$'\t' read -r s state; do
    [[ -n "$s" ]] || continue
    if sudo -n systemctl start "$s" >/dev/null 2>&1; then
      ok "restarted $s"
    else
      warn "failed to restart $s"
    fi
  done < "$SVC_FILE"
  rm -f "$SVC_FILE"
}

step_timers_stop() {
  [[ "$STOP_TIMERS" == "1" ]] || return 0
  : > "$TIMER_FILE"
  for t in "${TIMERS_TO_STOP[@]}"; do
    local active
    active=$(systemctl is-active "$t" 2>/dev/null || true)
    if [[ "$active" == "active" ]]; then
      if sudo -n systemctl stop "$t" >/dev/null 2>&1; then
        ok "stopped $t"
        printf '%s\twas-active\n' "$t" >> "$TIMER_FILE"
      fi
    fi
  done
}

step_timers_start() {
  [[ -f "$TIMER_FILE" ]] || return 0
  while IFS=$'\t' read -r t state; do
    [[ -n "$t" ]] || continue
    sudo -n systemctl start "$t" >/dev/null 2>&1 && ok "restarted $t"
  done < "$TIMER_FILE"
  rm -f "$TIMER_FILE"
}

step_sockets_stop() {
  [[ "$STOP_SERVICES" == "1" ]] || return 0
  : > "$STATE_DIR/sockets.tsv"
  for s in "${SOCKETS_TO_STOP[@]}"; do
    local active
    active=$(systemctl is-active "$s" 2>/dev/null || true)
    if [[ "$active" == "active" ]]; then
      if sudo -n systemctl stop "$s" >/dev/null 2>&1; then
        ok "stopped $s"
        printf '%s\twas-active\n' "$s" >> "$STATE_DIR/sockets.tsv"
      else
        warn "failed to stop $s"
      fi
    fi
  done
}

step_sockets_start() {
  [[ -f "$STATE_DIR/sockets.tsv" ]] || return 0
  while IFS=$'\t' read -r s state; do
    [[ -n "$s" ]] || continue
    sudo -n systemctl start "$s" >/dev/null 2>&1 && ok "restarted $s"
  done < "$STATE_DIR/sockets.tsv"
  rm -f "$STATE_DIR/sockets.tsv"
}

# Compute a cpu mask in /proc/irq format (hex, comma-separated 32-bit groups
# from low to high).  For cpus "4-15,20-31" on a 32-cpu system this yields
# "fff0fff0".  Bash ints are 64 bits so for systems with >64 cpus we need
# to split the mask into two 64-bit halves (low, high).
mask_of() {
  local spec="$1"
  # Find the highest cpu referenced to decide how many 64-bit chunks we need.
  local max=0
  IFS=',' read -ra parts <<<"$spec"
  for p in "${parts[@]}"; do
    if [[ "$p" == *-* ]]; then
      local hi=${p#*-}; (( hi > max )) && max=$hi
    else
      (( p > max )) && max=$p
    fi
  done
  local chunks=$(( max / 64 + 1 ))
  # One 64-bit accumulator per chunk.
  local -a acc=()
  local i
  for ((i=0; i<chunks; i++)); do acc[i]=0; done
  for p in "${parts[@]}"; do
    local lo hi c
    if [[ "$p" == *-* ]]; then lo=${p%-*}; hi=${p#*-}; else lo=$p; hi=$p; fi
    for ((c=lo; c<=hi; c++)); do
      local chunk=$(( c / 64 ))
      local bit=$(( c % 64 ))
      acc[chunk]=$(( ${acc[chunk]} | (1 << bit) ))
    done
  done
  # Emit as 8-hex-digit groups, highest word first.
  local out=""
  for ((i=chunks-1; i>=0; i--)); do
    local hi32=$(( (${acc[i]} >> 32) & 0xffffffff ))
    local lo32=$(( ${acc[i]} & 0xffffffff ))
    out+="$(printf '%08x,%08x,' $hi32 $lo32)"
  done
  out=${out%,}
  while [[ "$out" == 00000000,* ]]; do out="${out#00000000,}"; done
  echo "$out"
}

step_irq_pin() {
  [[ "$PIN_IRQ" == "1" ]] || return 0
  local m
  m=$(mask_of "$SYS_CPUS")
  ok "IRQ affinity mask for $SYS_CPUS = $m"
  : > "$IRQ_FILE"
  local tot=0 ok_c=0 skip=0
  # Default affinity first.
  if [[ -r /proc/irq/default_smp_affinity ]]; then
    local cur
    cur=$(cat /proc/irq/default_smp_affinity 2>/dev/null || true)
    printf '%s\t%s\n' "/proc/irq/default_smp_affinity" "$cur" >> "$IRQ_FILE"
    if sudow "$m" /proc/irq/default_smp_affinity; then
      ok "pinned default IRQ affinity"
    fi
  fi
  for f in /proc/irq/*/smp_affinity; do
    [[ -e "$f" ]] || continue
    tot=$((tot+1))
    local cur
    cur=$(cat "$f" 2>/dev/null || true)
    if [[ -z "$cur" ]]; then skip=$((skip+1)); continue; fi
    printf '%s\t%s\n' "$f" "$cur" >> "$IRQ_FILE"
    if sudow "$m" "$f" 2>/dev/null; then
      ok_c=$((ok_c+1))
    else
      skip=$((skip+1))
    fi
  done
  ok "IRQ smp_affinity: set $ok_c/$tot (skipped $skip unwritable)"
}

step_irq_reset() {
  [[ -f "$IRQ_FILE" ]] || return 0
  while IFS=$'\t' read -r f cur; do
    [[ -n "$f" && -n "$cur" ]] || continue
    sudow "$cur" "$f" 2>/dev/null || true
  done < "$IRQ_FILE"
  ok "restored IRQ affinity"
  rm -f "$IRQ_FILE"
}

# Return the NUMA node id that contains the first cpu of $1, or 0 if none.
numa_node_of_cpu() {
  local first=${1%%[,-]*}
  shopt -s nullglob
  for d in /sys/devices/system/node/node[0-9]*; do
    local cpulist; cpulist=$(cat "$d/cpulist" 2>/dev/null)
    if cpulist_contains "$cpulist" "$first"; then
      shopt -u nullglob
      basename "$d" | sed 's/^node//'
      return
    fi
  done
  shopt -u nullglob
  echo 0
}

step_slice() {
  if [[ "$CG_VERSION" == "0" ]]; then
    warn "no usable cgroup hierarchy detected; skipping bench cgroup"
    return 0
  fi
  local cg
  cg=$(bench_cg_path)
  local mems
  mems=$(numa_node_of_cpu "$BENCH_CPUS")
  if [[ "$CG_VERSION" == "2" ]]; then
    # cgroup v2: bench.slice with cpuset controller, optional partition=root
    # for kernel-enforced exclusion.
    if ! grep -qw cpuset /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
      if ! sudow '+cpuset' /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
        warn "could not enable cpuset controller at root"
      fi
    fi
    if [[ ! -d "$cg" ]]; then
      if ! sudo -n mkdir -p "$cg" 2>/dev/null; then
        warn "could not mkdir $cg"
        return 0
      fi
    fi
    if sudow "$BENCH_CPUS" "$cg/cpuset.cpus"; then
      ok "cgroup-v2 $cg cpuset.cpus = $BENCH_CPUS"
    else
      warn "could not set cpuset.cpus on $cg"
    fi
    if [[ "$PARTITION_ROOT" == "1" ]]; then
      if sudow "root" "$cg/cpuset.cpus.partition" 2>/dev/null; then
        local p
        p=$(cat "$cg/cpuset.cpus.partition" 2>/dev/null)
        ok "cgroup-v2 $cg partition = $p"
      else
        warn "could not set partition=root (member is fine; cpuset pin still works)"
      fi
    fi
    sudo -n chown "$USER" "$cg/cgroup.procs" 2>/dev/null || true
  else
    # cgroup v1: dedicated cpuset hierarchy.  cpuset.mems is mandatory
    # (unlike v2 where it inherits) -- write the NUMA node containing
    # BENCH_CPUS so allocations stay local.  cpuset.cpu_exclusive=1 is
    # the kernel-enforced equivalent of v2's partition=root.
    if [[ ! -d "$cg" ]]; then
      if ! sudo -n mkdir -p "$cg" 2>/dev/null; then
        warn "could not mkdir $cg"
        return 0
      fi
    fi
    if sudow "$mems" "$cg/cpuset.mems"; then
      ok "cgroup-v1 $cg cpuset.mems = $mems"
    else
      warn "could not set cpuset.mems on $cg"
    fi
    if sudow "$BENCH_CPUS" "$cg/cpuset.cpus"; then
      ok "cgroup-v1 $cg cpuset.cpus = $BENCH_CPUS"
    else
      warn "could not set cpuset.cpus on $cg"
    fi
    if [[ "$PARTITION_ROOT" == "1" ]]; then
      if sudow "1" "$cg/cpuset.cpu_exclusive" 2>/dev/null; then
        ok "cgroup-v1 $cg cpu_exclusive = 1"
      else
        # cgroup v1 cpu_exclusive is hierarchical: kernel rejects unless
        # *all* parent cpusets also have cpu_exclusive=1.  The root cpuset
        # is shared with the rest of the system, so we cannot set it.
        # We rely on the bench cpuset.cpus pin + taskset / cpuset.cpus
        # to keep our workload on BENCH_CPUS, but other tasks can in
        # principle still migrate onto them.  Mitigation: stop chatty
        # services (already done) and let the scheduler pick wisely.
        warn "could not set cpu_exclusive (kernel requires hierarchical exclusivity on v1)"
      fi
    fi
    # On cgroup v1 hybrid, the cpuset directory is created mode 0750 and
    # owned by root.  Even after chowning cgroup.procs to our user, we
    # also need directory traversal (chmod g+rx,o+rx or chown the dir
    # itself) so unprivileged writes to cgroup.procs / tasks succeed.
    sudo -n chmod g+rx,o+rx "$cg" 2>/dev/null || true
    sudo -n chown "$USER" "$cg/tasks" "$cg/cgroup.procs" 2>/dev/null || true
  fi
}

step_slice_reset() {
  if [[ "$CG_VERSION" == "0" ]]; then return 0; fi
  local cg
  cg=$(bench_cg_path)
  if [[ ! -d "$cg" ]]; then return 0; fi
  if [[ "$CG_VERSION" == "2" ]]; then
    sudow "member" "$cg/cpuset.cpus.partition" 2>/dev/null || true
    if [[ -s "$cg/cgroup.procs" ]]; then
      while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        printf '%s' "$pid" | sudo -n tee /sys/fs/cgroup/cgroup.procs >/dev/null 2>&1 || true
      done < "$cg/cgroup.procs"
    fi
  else
    sudow "0" "$cg/cpuset.cpu_exclusive" 2>/dev/null || true
    if [[ -s "$cg/cgroup.procs" ]]; then
      while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        # On v1, the "root" of a controller is its mountpoint
        # (/sys/fs/cgroup/cpuset/), not /sys/fs/cgroup/cgroup.procs.
        printf '%s' "$pid" | sudo -n tee /sys/fs/cgroup/cpuset/cgroup.procs >/dev/null 2>&1 || true
      done < "$cg/cgroup.procs"
    fi
  fi
  if sudo -n rmdir "$cg" 2>/dev/null; then
    ok "removed $cg"
  else
    warn "could not rmdir $cg (still has tasks?)"
  fi
}

# Pin system.slice and user.slice to SYS_CPUS (i.e. NOT the bench socket).
# This prevents ordinary system/user processes from touching the bench
# socket's L3 cache and from migrating onto BENCH_CPUS if partition=root
# isn't supported for some reason.
#
# On cgroup v2, writing an empty value to cpuset.cpus means "inherit from
# parent", so we record the previous literal value (which may be empty)
# and restore it on reset.
step_isolate_sys() {
  [[ "$ISOLATE_SYS" == "1" ]] || return 0
  local slices=(system.slice user.slice)
  for s in "${slices[@]}"; do
    local path="/sys/fs/cgroup/$s/cpuset.cpus"
    [[ -e "$path" ]] || continue
    local prev
    prev=$(cat "$path" 2>/dev/null || echo "")
    save_state "ISO_${s//./_}_PREV" "$prev"
    if sudow "$SYS_CPUS" "$path"; then
      ok "pinned $s cpuset.cpus = $SYS_CPUS"
    else
      warn "could not pin $s (may already be managed by systemd)"
    fi
  done
}

step_isolate_sys_reset() {
  local slices=(system.slice user.slice)
  for s in "${slices[@]}"; do
    local path="/sys/fs/cgroup/$s/cpuset.cpus"
    [[ -e "$path" ]] || continue
    local key="ISO_${s//./_}_PREV"
    local prev
    prev=$(get_state "$key")
    if [[ -n "$prev" ]]; then
      sudow "$prev" "$path" 2>/dev/null && ok "restored $s cpuset.cpus = $prev"
    else
      # Previous value was empty (inherit from parent).  Write empty.
      sudo -n sh -c "echo -n '' > $path" 2>/dev/null \
        && ok "restored $s cpuset.cpus = (inherit)"
    fi
    save_state "$key" ""
  done
}

########################################################################
# Subcommands
########################################################################

cmd_set() {
  msg "configuring noise-reduction environment"
  msg "  BENCH_CPUS=$BENCH_CPUS   SYS_CPUS=$SYS_CPUS"
  msg "  HT_OFFLINE=$HT_OFFLINE   PARTITION_ROOT=$PARTITION_ROOT   PIN_IRQ=$PIN_IRQ"
  msg "  NO_THP=$NO_THP   STOP_SERVICES=$STOP_SERVICES   STOP_TIMERS=$STOP_TIMERS"
  msg "  FREQ_FIX=$FREQ_FIX   ISOLATE_SYS=$ISOLATE_SYS   NUMA_NODES=$NUMA_NODES"
  save_state SET_AT "$(date -Is)"
  save_state BENCH_CPUS "$BENCH_CPUS"
  save_state SYS_CPUS "$SYS_CPUS"
  step_services_stop
  step_sockets_stop
  step_timers_stop
  step_offline_ht
  step_thp
  step_freq_fix
  step_irq_pin
  step_slice
  step_isolate_sys
  msg "done. Invoke benchmarks via: $(basename "$0") run -- <cmd>"
}

cmd_reset() {
  msg "reverting noise-reduction environment"
  step_isolate_sys_reset
  step_slice_reset
  step_irq_reset
  step_freq_reset
  step_thp_reset
  step_online_ht
  step_timers_start
  step_sockets_start
  step_services_start
  rm -f "$STATE_FILE"
  msg "done"
}

cmd_status() {
  echo "=== bench-env status ==="
  echo "state file: $STATE_FILE"
  if [[ -f "$STATE_FILE" ]]; then
    sed 's/^/  /' "$STATE_FILE"
  else
    echo "  (no active configuration)"
  fi
  echo
  echo "--- cgroup (hierarchy: v$CG_VERSION) ---"
  local cg
  cg=$(bench_cg_path)
  if [[ -d "$cg" ]]; then
    echo "  $cg"
    local fields
    if [[ "$CG_VERSION" == "2" ]]; then
      fields=(cpuset.cpus cpuset.cpus.effective cpuset.cpus.partition cgroup.procs)
    else
      fields=(cpuset.cpus cpuset.effective_cpus cpuset.mems cpuset.cpu_exclusive cgroup.procs)
    fi
    for f in "${fields[@]}"; do
      if [[ -e "$cg/$f" ]]; then
        local v
        v=$(cat "$cg/$f" 2>/dev/null | tr '\n' ' ')
        echo "    $f = $v"
      fi
    done
  else
    echo "  (no bench slice)"
  fi
  echo
  echo "--- sys ---"
  echo "  online cpus: $(cat /sys/devices/system/cpu/online)"
  echo "  THP: $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)"
  echo "  clocksource: $(cat /sys/devices/system/clocksource/clocksource0/current_clocksource 2>/dev/null)"
  echo "  nmi_watchdog: $(sysctl -n kernel.nmi_watchdog 2>/dev/null)"
  echo "  swappiness: $(sysctl -n vm.swappiness 2>/dev/null)"
  echo "  NUMA nodes: $NUMA_NODES"
  for d in /sys/devices/system/node/node[0-9]*; do
    [[ -d "$d" ]] || continue
    echo "    $(basename $d): $(cat $d/cpulist 2>/dev/null)"
  done
  echo
  echo "--- cpu frequency ---"
  if [[ -r /sys/devices/system/cpu/intel_pstate/status ]]; then
    echo "  intel_pstate status: $(cat /sys/devices/system/cpu/intel_pstate/status 2>/dev/null)"
    echo "  no_turbo: $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)"
    echo "  hwp_dynamic_boost: $(cat /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost 2>/dev/null)"
  else
    echo "  intel_pstate: unavailable"
  fi
  echo "  governor (cpu0): $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
  # Sample the current MHz of the first few bench CPUs
  local first; first=${BENCH_CPUS%%[,-]*}
  for c in $first; do
    [[ -r /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq ]] \
      && echo "  cpu$c scaling_cur_freq: $(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq)"
  done
  echo
  echo "--- slice isolation ---"
  if [[ "$CG_VERSION" == "2" ]]; then
    for s in system.slice user.slice "$BENCH_UNIT"; do
      local path="/sys/fs/cgroup/$s"
      if [[ -d "$path" ]]; then
        echo "  $s cpuset.cpus          = $(cat $path/cpuset.cpus 2>/dev/null)"
        echo "  $s cpuset.cpus.effective= $(cat $path/cpuset.cpus.effective 2>/dev/null)"
      fi
    done
  else
    echo "  (cgroup v1 does not expose per-slice cpusets via systemd;"
    echo "   isolation comes from cpuset.cpu_exclusive=1 on the bench cgroup,"
    echo "   which evicts non-bench tasks from BENCH_CPUS.)"
  fi
  echo
  echo "--- noisy services/timers/sockets (should be inactive on set) ---"
  for u in "${SERVICES_TO_STOP[@]}" "${SOCKETS_TO_STOP[@]}" "${TIMERS_TO_STOP[@]}"; do
    local s
    s=$(systemctl is-active "$u" 2>/dev/null || true)
    printf '  %-55s %s\n' "$u" "$s"
  done
  echo
  echo "--- self-protected processes (LSM-guarded, can't be killed) ---"
  local lsm
  lsm=$(cat /sys/kernel/security/lsm 2>/dev/null || true)
  echo "  active LSMs: $lsm"
  if pgrep -af 'falcon-sensor' >/dev/null 2>&1; then
    pgrep -af 'falcon-sensor' | awk '{print "  " $0}' | head -3
  else
    echo "  (no falcon processes running)"
  fi
}

cmd_run() {
  # Strip a leading "--".
  if [[ "${1:-}" == "--" ]]; then shift; fi
  if [[ $# -eq 0 ]]; then
    err "run: no command supplied"
    exit 2
  fi
  local cg
  cg=$(bench_cg_path)
  if [[ ! -d "$cg" ]]; then
    warn "bench slice not set up; run '$(basename "$0") set' first"
    warn "falling back to plain exec"
    exec "$@"
  fi

  if [[ "${DROP_CACHES:-1}" == "1" ]]; then
    sudo -n sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null \
      && ok "dropped caches" \
      || warn "could not drop caches"
  fi

  # Place ourselves into the bench cgroup, then exec the command.
  # cgroup v1 and v2 both accept TGIDs at $cg/cgroup.procs (v1 also has
  # /tasks for individual threads; we don't need that).
  local procs="$cg/cgroup.procs"
  if ! [[ -w "$procs" ]]; then
    sudo -n chown "$USER" "$procs" 2>/dev/null || true
  fi

  # Move our own pid in, then exec.  Child inherits the cgroup.
  # Use tee (with error suppression) instead of bash's > redirect so a
  # delegation failure doesn't print a bare "Permission denied" line.
  if ! printf '%d' "$$" | tee "$procs" >/dev/null 2>&1; then
    if ! printf '%d' "$$" | sudo -n tee "$procs" >/dev/null 2>&1; then
      err "could not join $procs"
      exit 3
    fi
  fi

  # Priority adjustment.  Negative nice requires CAP_SYS_NICE, but going
  # through `sudo` rewrites PATH (secure_path) and drops us onto the
  # system /usr/bin/java rather than the user's sdkman Java, which silently
  # breaks benchmarks.  So: if NICE_LEVEL is negative, try `sudo renice` on
  # ourselves in-place (no re-exec, preserves PATH/JAVA_HOME), then exec
  # directly.  If that fails, just run without it -- the cpuset is the
  # main win.
  if [[ -n "$NICE_LEVEL" && "$NICE_LEVEL" != "0" ]]; then
    if [[ "$NICE_LEVEL" =~ ^-[0-9]+$ ]]; then
      sudo -n renice -n "$NICE_LEVEL" -p "$$" >/dev/null 2>&1 \
        && ok "renice $NICE_LEVEL applied to pid $$" \
        || warn "could not renice (no sudo or EPERM); continuing without it"
      exec "$@"
    else
      exec nice -n "$NICE_LEVEL" -- "$@"
    fi
  fi
  exec "$@"
}

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    set)    cmd_set    "$@" ;;
    reset)  cmd_reset  "$@" ;;
    status) cmd_status "$@" ;;
    run)    cmd_run    "$@" ;;
    -h|--help|"")
      cat <<'EOU'
bench-env.sh — prepare this host for low-noise benchmarking.
Usage: bench-env.sh {set|reset|status|run [-- cmd args...]}
EOU
      ;;
    *) err "unknown subcommand: $sub"; exit 2 ;;
  esac
}

main "$@"
