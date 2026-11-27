#!/usr/bin/env bash
# Exercise the package-lock comparison in strict NEVRA equality mode without a built image.
# The strict comparator exits 0 only for exact NEVRA equality after lock-filter and sorting.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compare_sh=$repo_root/build/compare-lock.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

recorded=$work/recorded.lock
cat >"$recorded" <<'LOCK'
mesa-vulkan-drivers-1:26.2.6-1.fc45.i686	rpmfusion-free
mesa-vulkan-drivers-1:26.2.6-1.fc45.x86_64	rpmfusion-free
steam-0:1.0.0.87-4.fc45.x86_64	rpmfusion-nonfree
LOCK

# Identical inputs -> exit 0
status=0
bash "$compare_sh" --strict "$recorded" "$recorded" >"$work/out" 2>"$work/err" || status=$?
if ((status != 0)); then
  echo "FAIL identical inputs exited ${status}, expected 0" >&2
  failures=$((failures + 1))
else
  echo "ok   identical inputs match and print nothing"
fi

# Rebuilt NEVRA inside same pair -> strict mode must fail (exit 1) and name the line
rebuilt=$work/rebuilt.lock
cat >"$rebuilt" <<'LOCK'
mesa-vulkan-drivers-1:26.2.6-1.fc45.x86_64	rpmfusion-free
mesa-vulkan-drivers-1:26.2.6-2.fc45.i686	rpmfusion-free
steam-0:1.0.0.87-4.fc45.x86_64	rpmfusion-nonfree
LOCK
status=0
bash "$compare_sh" --strict "$recorded" "$rebuilt" >"$work/out" 2>"$work/err" || status=$?
if ((status != 1)); then
  echo "FAIL a rebuilt NEVRA exited ${status}, expected 1" >&2
  failures=$((failures + 1))
elif ! grep -qF -- '-mesa-vulkan-drivers-1:26.2.6-1.fc45.i686' "$work/err" || ! grep -qF -- '+mesa-vulkan-drivers-1:26.2.6-2.fc45.i686' "$work/err"; then
  echo "--- comparator stderr ---" >&2
  cat "$work/err" >&2
  echo "FAIL rebuilt NEVRA did not print the diff lines" >&2
  failures=$((failures + 1))
else
  echo "ok   a rebuilt NEVRA causes strict comparator to fail and prints the diff"
fi

# Missing package -> exit 1
# The measurement omits the recorded steam line entirely. Expect a single
# '-' line naming the removed package and no '+steam-0:' line.
missing=$work/missing.lock
cat >"$missing" <<'LOCK'
mesa-vulkan-drivers-1:26.2.6-1.fc45.i686	rpmfusion-free
mesa-vulkan-drivers-1:26.2.6-1.fc45.x86_64	rpmfusion-free
LOCK
status=0
bash "$compare_sh" --strict "$recorded" "$missing" >"$work/out" 2>"$work/err" || status=$?
if ((status != 1)); then
  echo "--- comparator stderr ---" >&2
  cat "$work/err" >&2
  echo "FAIL a missing package exited ${status}, expected 1" >&2
  failures=$((failures + 1))
elif ! grep -qF -- '-steam-0:1.0.0.87-4.fc45.x86_64' "$work/err"; then
  echo "--- comparator stderr ---" >&2
  cat "$work/err" >&2
  echo "FAIL missing package did not print the removed -steam line" >&2
  failures=$((failures + 1))
elif grep -qF -- '+steam-0:' "$work/err"; then
  echo "--- comparator stderr ---" >&2
  cat "$work/err" >&2
  echo "FAIL missing package printed an unexpected +steam line" >&2
  failures=$((failures + 1))
else
  echo "ok   a missing package causes strict comparator to fail and names it"
fi

# Extra package -> exit 1
# The measurement adds dms-cli while leaving all recorded lines present. Expect
# a single '+dms-cli' line and no '-dms-cli' line.
extra=$work/extra.lock
cat >"$extra" <<'LOCK'
mesa-vulkan-drivers-1:26.2.6-1.fc45.i686	rpmfusion-free
mesa-vulkan-drivers-1:26.2.6-1.fc45.x86_64	rpmfusion-free
steam-0:1.0.0.87-4.fc45.x86_64	rpmfusion-nonfree
dms-cli-0:2.1.2-1.fc45.x86_64	copr:copr.fedorainfracloud.org:duxlabs:dms
LOCK
status=0
bash "$compare_sh" --strict "$recorded" "$extra" >"$work/out" 2>"$work/err" || status=$?
if ((status != 1)); then
  echo "--- comparator stderr ---" >&2
  cat "$work/err" >&2
  echo "FAIL an extra package exited ${status}, expected 1" >&2
  failures=$((failures + 1))
elif ! grep -qF -- '+dms-cli' "$work/err"; then
  echo "--- comparator stderr ---" >&2
  cat "$work/err" >&2
  echo "FAIL an extra package did not print the added +dms-cli line" >&2
  failures=$((failures + 1))
elif grep -qF -- '-dms-cli' "$work/err"; then
  echo "--- comparator stderr ---" >&2
  cat "$work/err" >&2
  echo "FAIL an extra package printed an unexpected -dms-cli line" >&2
  failures=$((failures + 1))
else
  echo "ok   an extra package causes strict comparator to fail and names it"
fi

# Empty input -> exit 2
: >"$work/empty.lock"
status=0
bash "$compare_sh" --strict "$recorded" "$work/empty.lock" >"$work/out" 2>"$work/err" || status=$?
if ((status != 2)); then
  echo "FAIL an empty measurement exited ${status}, expected 2" >&2
  failures=$((failures + 1))
else
  echo "ok   an empty measurement exits 2"
fi

# Unreadable input -> exit 2
status=0
bash "$compare_sh" --strict "$recorded" "$work/absent.lock" >"$work/out" 2>"$work/err" || status=$?
if ((status != 2)); then
  echo "FAIL an unreadable measurement exited ${status}, expected 2" >&2
  failures=$((failures + 1))
else
  echo "ok   an unreadable measurement exits 2"
fi

# Comment-only lock -> exit 2
comment_only=$work/comment.lock
cat >"$comment_only" <<'LOCK'
# just comments
# another comment
LOCK
status=0
bash "$compare_sh" --strict "$recorded" "$comment_only" >"$work/out" 2>"$work/err" || status=$?
if ((status != 2)); then
  echo "FAIL a comment-only lock exited ${status}, expected 2" >&2
  failures=$((failures + 1))
else
  echo "ok   a comment-only lock exits 2"
fi

if ((failures > 0)); then
  exit 1
fi
