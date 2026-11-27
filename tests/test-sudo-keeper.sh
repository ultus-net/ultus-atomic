#!/usr/bin/env bash
# Replay the two end-of-boot ticket probes from the server boot test against
# prepared states. A keeper that died, and a boot that ends between two ticks,
# must both red here instead of after a 45-minute guest run (#169).
#
# The probe text is read from tests/vm/boot-smoke-server.sh, so this test cannot
# drift from the guest. Only the log directory and the 130s poll bound change.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
boot_test=${1:-$repo_root/tests/vm/boot-smoke-server.sh}
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
failures=0

probe_command() {
  local nth=$1 line
  line=$(grep -F "probe 'ULTUS_SUDO_TICKET:ok'" "$boot_test" | sed -n "${nth}p")
  if [[ -z $line ]]; then
    echo "FAIL no end-of-boot ticket probe number ${nth} in ${boot_test}" >&2
    exit 1
  fi
  printf '%s\n' "$line" | awk -F"'" '{print $4}'
}

check() {
  local name=$1 expected=$2 nth=$3 dir=$4
  local cmd got
  cmd=$(probe_command "$nth")
  cmd=${cmd//\/tmp\/sudo-keep/$dir\/sudo-keep}
  cmd=${cmd//seq 1 130/seq 1 4}
  got=$(eval "$cmd")
  if [[ $got == "$expected" ]]; then
    echo "ok   ${name}: ${got}"
  else
    echo "FAIL ${name}: expected '${expected}', got '${got}'" >&2
    failures=$((failures + 1))
  fi
}

lines() {
  local file=$1 count=$2 i
  : >"$file"
  for ((i = 0; i < count; i++)); do printf '%s\n' "$i" >>"$file"; done
}

boot1() {
  local name=$1 expected=$2 start=$3 count=$4 fails=$5 late=$6
  local dir
  dir=$(mktemp -d "$root/boot1-XXXX")
  printf '%s\n' "$start" >"$dir/sudo-keep.start"
  lines "$dir/sudo-keep.log" "$count"
  ((fails)) && printf '1\n' >"$dir/sudo-keep.fail"
  ((late)) && (sleep 1; printf 'late\n' >>"$dir/sudo-keep.log") &
  check "$name" "$expected" 1 "$dir"
  wait
}

boot2() {
  local name=$1 expected=$2 count=$3 fails=$4 late=$5
  local dir
  dir=$(mktemp -d "$root/boot2-XXXX")
  lines "$dir/sudo-keep2.log" "$count"
  ((fails)) && printf '1\n' >"$dir/sudo-keep2.fail"
  ((late)) && (sleep 1; printf 'tick1\n' >>"$dir/sudo-keep2.log"; sleep 1; printf 'tick2\n' >>"$dir/sudo-keep2.log") &
  check "$name" "$expected" 2 "$dir"
  wait
}

boot1 'grew by one' 'ULTUS_SUDO_TICKET:ok refreshes=4' 3 3 0 1
boot1 'dead keeper' 'ULTUS_SUDO_TICKET:stale start=3 now=3 fails=0' 3 3 0 0
boot1 'failed refresh' 'ULTUS_SUDO_TICKET:stale start=3 now=4 fails=1' 3 4 1 0
boot2 'already two' 'ULTUS_SUDO_TICKET:ok refreshes=2' 2 0 0
boot2 'empty log' 'ULTUS_SUDO_TICKET:stale now=0 fails=0' 0 0 0
boot2 'two arrive late' 'ULTUS_SUDO_TICKET:ok refreshes=2' 0 0 1
boot2 'failed refresh' 'ULTUS_SUDO_TICKET:stale now=2 fails=1' 2 1 0

if ((failures)); then
  echo "FAIL ${failures} ticket keeper case(s) regressed" >&2
  exit 1
fi
echo "ok   the ticket keeper cases hold"
