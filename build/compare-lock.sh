#!/usr/bin/env bash
# Compare the recorded package lock with a measured package list.
#
#   build/compare-lock.sh <recorded-lock> <measured-list>
#
# Contract: exit 0 when both inputs name the same <package> TAB <origin repo>
# pairs. A recorded package whose NEVRA moved inside its pair prints a warning
# on stderr and still exits 0, because a third-party rebuild is not a change
# this gate blocks. Exit 1 when a package appears, disappears or changes origin
# repository, and print those pairs on stderr. Exit 2 when an input is
# unreadable or has no data lines, so a failed measurement never looks like
# drift. The measured list drops unpinnable NEVRAs the same way
# build/package-lock.sh does.

set -euo pipefail

if (( $# != 2 )); then
  echo "usage: build/compare-lock.sh <recorded-lock> <measured-list>" >&2
  exit 2
fi

recorded_path=$1
measured_path=$2

if [[ ! -r $recorded_path || ! -r $measured_path ]]; then
  echo "build/compare-lock.sh: cannot read an input: ${recorded_path} ${measured_path}" >&2
  exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

recorded=$(grep -vE '^(#|$)' "$recorded_path" || true)
measured=$(grep -vE '^(#|$)' "$measured_path" || true)
if [[ -z $recorded || -z $measured ]]; then
  echo "build/compare-lock.sh: an input has no data lines: ${recorded_path} ${measured_path}" >&2
  exit 2
fi

measured=$(awk -f "$script_dir/lock-filter.awk" <<<"$measured")
recorded=$(LC_ALL=C sort -u <<<"$recorded")
measured=$(LC_ALL=C sort -u <<<"$measured")

if [[ $recorded == "$measured" ]]; then
  exit 0
fi

# Reduce an NEVRA to its package name, so the pair key survives a rebuild.
#
# The lock records %{full_nevra}, which always carries an epoch:
# name-epoch:version-release.arch. Only a line in that shape is reduced. A line
# that does not match keeps its whole NEVRA, so it compares equal only to
# itself, and an unrecognised line blocks instead of passing as a warning.
pair_key() {
  awk -F'\t' '{
    name = $1
    if (name ~ /-[0-9]+:.+-[^-]+\.[^-]+$/) {
      sub(/\.[^.]*$/, "", name)
      sub(/-[^-]*$/, "", name)
      sub(/-[0-9]+:.*$/, "", name)
    }
    print name "\t" $2
  }'
}

recorded_pairs=$(pair_key <<<"$recorded" | LC_ALL=C sort -u)
measured_pairs=$(pair_key <<<"$measured" | LC_ALL=C sort -u)

if [[ $recorded_pairs != "$measured_pairs" ]]; then
  diff -u <(printf '%s\n' "$recorded_pairs") <(printf '%s\n' "$measured_pairs") >&2 || true
  exit 1
fi

printf 'warning: the third-party lock records an older build of these packages; run just lock to refresh it\n' >&2
diff -u <(printf '%s\n' "$recorded") <(printf '%s\n' "$measured") \
  | grep -E '^[-+][a-z0-9]' >&2 || true
exit 0
