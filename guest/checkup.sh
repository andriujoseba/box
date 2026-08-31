#!/usr/bin/env bash
set -euo pipefail

# Read-only guest fitness report, streamed into one box by `box checkup` (#258).
# Positional inputs are host facts the guest cannot discover honestly:
# instance type, the mint's seed marker, and a container's expanded swap policy.
kind="${1:-}"
seed="${2:-unknown}"
swap_policy="${3:-default}"
case "$kind" in vm|container) ;; *) echo "checkup: expected vm or container" >&2; exit 2 ;; esac

gib() {
  awk -v bytes="$1" 'BEGIN { printf "%.1f GiB", bytes / 1073741824 }'
}

problems=0
printf '%-9s%s\n' TYPE "$( [ "$kind" = vm ] && echo VM || echo CONTAINER )"
case "$seed" in
  unknown) printf '%-9s%s\n' SEED "unknown — this box carries no seed-generation marker" ;;
  *)       printf '%-9s%s\n' SEED "$seed" ;;
esac

# Headroom is evidence, not a threshold. 81% used is worth seeing and is not a
# failure, so these two rows never change the exit status (#258 D4).
disk_row="$(df -B1 --output=size,avail,pcent / | awk 'NR == 2 { print $1, $2, $3 }')"
read -r disk_total disk_available disk_used <<<"$disk_row"
printf '%-9s%s available of %s (%s used)\n' DISK \
  "$(gib "$disk_available")" "$(gib "$disk_total")" "$disk_used"

memory_row="$(free -b | awk '/^Mem:/ { print $2, $7 }')"
read -r mem_total mem_available <<<"$memory_row"
printf '%-9s%s available of %s\n' MEMORY \
  "$(gib "$mem_available")" "$(gib "$mem_total")"

tmp_row="$(findmnt -bn -o FSTYPE,SIZE,OPTIONS /tmp)"
read -r tmp_fstype tmp_size tmp_options <<<"$tmp_row"
printf '%-9s%s at %s (%s)\n' TMP "$tmp_fstype" "$(gib "$tmp_size")" "$tmp_options"
# The measured legacy shape was systemd's stock 50%-of-RAM tmpfs. Allow a
# small accounting margin rather than demanding byte equality.
if [ "$tmp_fstype" = tmpfs ] \
  && [ "$tmp_size" -gt $((mem_total * 45 / 100)) ] \
  && [ "$tmp_size" -lt $((mem_total * 55 / 100)) ]; then
  if [ "$kind" = container ]; then
    echo "FIX       /tmp is about 50% of the container's reported memory; remint with tenant seed #178 for the fixed 1.0 GiB cap."
  else
    echo "FIX       /tmp is about 50% of VM memory; remint with tenant seed #178 for the fixed 1.0 GiB cap."
  fi
  problems=$((problems + 1))
fi

if [ "$kind" = container ]; then
  printf '%-9s%s\n' SWAP "host-managed for this container (limits.memory.swap=$swap_policy)"
else
  swap_total="$(free -b | awk '/^Swap:/ { print $2 }')"
  if [ "${swap_total:-0}" -eq 0 ]; then
    echo "SWAP     none"
    echo "FIX       missing swap; remint with tenant seed #178 for its 4.0 GiB swapfile."
    problems=$((problems + 1))
  else
    printf '%-9s%s total\n' SWAP "$(gib "$swap_total")"
  fi
fi

# One capture preserves journalctl's status without writing an error file. The
# probe runs as root through Incus, but a missing journal or explicit denial is
# still unknown, never "no OOM" — the false negative that bought this check.
journal_rc=0
# _TRANSPORT=kernel instead of `-k`: journalctl -k implies the current boot,
# while "ever logged" means every retained boot in this guest (#258).
journal="$(journalctl --no-pager -o cat _TRANSPORT=kernel 2>&1)" || journal_rc=$?
if [ "$journal_rc" -ne 0 ] \
  || grep -qiE 'permission denied|not seeing messages|no journal files|failed to open' <<<"$journal"; then
  printf '%-9s%s\n' OOM "could not read kernel journal${journal:+ — $journal}"
  problems=$((problems + 1))
else
  oom_count="$(grep -ciE 'oom-kill|out of memory|killed process [0-9]+' <<<"$journal" || true)"
  if [ "$oom_count" -eq 0 ]; then
    printf '%-9s%s\n' OOM "no OOM kill logged"
  else
    printf '%-9s%s\n' OOM "$oom_count OOM kill record(s) logged"
    problems=$((problems + 1))
  fi
fi

[ "$problems" -eq 0 ] || exit 1
