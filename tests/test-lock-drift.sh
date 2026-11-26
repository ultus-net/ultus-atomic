#!/usr/bin/env bash
# Exercise the package-lock comparison without a built image.
# build/compare-lock.sh is the code tests/verify-image.sh runs against the image.
#
# The gate blocks on which packages come from where, and warns on which build of
# them landed. A third-party rebuild is not something a pull request should wait
# on; a package that appears, disappears or changes origin repository is.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compare=$repo_root/build/compare-lock.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# This is a synthetic fixture rather than a copy of lock lines, because the
# lock's own content moves with the provider: since the RPM Fusion migration
# (#112), steam is recorded from rpmfusion-nonfree and mesa-vulkan-drivers is
# Fedora-origin and therefore unrecorded. The shape is what matters.
# mesa-vulkan-drivers is a manifest name, steam is another, and steam pulls the
# 32-bit mesa stack in transitively (see tests/verify-image.sh:50-53), so the
# i686 line is the transitive case.
recorded=$work/recorded.lock
cat >"$recorded" <<'LOCK'
mesa-vulkan-drivers-1:26.2.6-1.fc45.i686	rpmfusion-free
mesa-vulkan-drivers-1:26.2.6-1.fc45.x86_64	rpmfusion-free
steam-0:1.0.0.87-4.fc45.x86_64	rpmfusion-nonfree
LOCK

status=0
"$compare" "$recorded" "$recorded" >"$work/out" 2>"$work/err" || status=$?
if ((status != 0)); then
  echo "FAIL identical inputs exited ${status}, expected 0" >&2
  failures=$((failures + 1))
elif [[ -s $work/out || -s $work/err ]]; then
  echo "FAIL identical inputs printed output" >&2
  failures=$((failures + 1))
else
  echo "ok   identical inputs match and print nothing"
fi

# Case 2 bumps the transitive i686 NEVRA's release from 1 to 2. The package and
# its origin repository are unchanged, so this is a rebuild: warn, exit 0.
# Five lock refreshes in twelve days were this class, and blocking on them held
# every open pull request.
rebuilt=$work/rebuilt.lock
cat >"$rebuilt" <<'LOCK'
mesa-vulkan-drivers-1:26.2.6-1.fc45.x86_64	rpmfusion-free
mesa-vulkan-drivers-1:26.2.6-2.fc45.i686	rpmfusion-free
steam-0:1.0.0.87-4.fc45.x86_64	rpmfusion-nonfree
LOCK
status=0
"$compare" "$recorded" "$rebuilt" >"$work/out" 2>"$work/err" || status=$?
if ((status != 0)); then
  echo "FAIL a rebuilt NEVRA exited ${status}, expected 0 (warn only)" >&2
  failures=$((failures + 1))
elif [[ -s $work/out ]]; then
  echo "FAIL a rebuilt NEVRA wrote to stdout" >&2
  failures=$((failures + 1))
elif ! grep -qF 'warning:' "$work/err" ||
     ! grep -qF -- '-mesa-vulkan-drivers-1:26.2.6-1.fc45.i686' "$work/err" ||
     ! grep -qF -- '+mesa-vulkan-drivers-1:26.2.6-2.fc45.i686' "$work/err"; then
  echo "FAIL a rebuilt NEVRA did not warn with both lines" >&2
  failures=$((failures + 1))
else
  echo "ok   a rebuilt NEVRA warns and still exits 0"
fi

# Case 3 adds a package the lock does not record. That is the supply-chain event
# the gate still blocks on, and it must name the package.
added=$work/added.lock
cat >"$added" <<'LOCK'
dms-cli-0:2.1.2-1.fc45.x86_64	copr:copr.fedorainfracloud.org:duxlabs:dms
mesa-vulkan-drivers-1:26.2.6-1.fc45.i686	rpmfusion-free
mesa-vulkan-drivers-1:26.2.6-1.fc45.x86_64	rpmfusion-free
steam-0:1.0.0.87-4.fc45.x86_64	rpmfusion-nonfree
LOCK
status=0
"$compare" "$recorded" "$added" >"$work/out" 2>"$work/err" || status=$?
if ((status != 1)); then
  echo "FAIL an added package exited ${status}, expected 1" >&2
  failures=$((failures + 1))
elif ! grep -qF -- '+dms-cli' "$work/err"; then
  echo "FAIL an added package was not named" >&2
  failures=$((failures + 1))
else
  echo "ok   an added package blocks and is named"
fi

# Case 4 moves a recorded package to a different origin repository. The name and
# the NEVRA are unchanged and the provenance is not, so it blocks.
moved=$work/moved-origin.lock
cat >"$moved" <<'LOCK'
mesa-vulkan-drivers-1:26.2.6-1.fc45.i686	rpmfusion-free
mesa-vulkan-drivers-1:26.2.6-1.fc45.x86_64	rpmfusion-free
steam-0:1.0.0.87-4.fc45.x86_64	copr:copr.fedorainfracloud.org:duxlabs:dux-repo
LOCK
status=0
"$compare" "$recorded" "$moved" >"$work/out" 2>"$work/err" || status=$?
if ((status != 1)); then
  echo "FAIL a changed origin repository exited ${status}, expected 1" >&2
  failures=$((failures + 1))
elif ! grep -qF -- '-steam' "$work/err" || ! grep -qF -- '+steam' "$work/err"; then
  echo "FAIL a changed origin repository did not name both pairs" >&2
  failures=$((failures + 1))
else
  echo "ok   a changed origin repository blocks and names both pairs"
fi

# Case 5 adds a +git NEVRA to the measurement. The helper drops it the way
# build/package-lock.sh drops it, so an extra +git line must not count as drift.
# This line is reconstructed rather than copied: manifests/packages-common.lock
# no longer carries it, so the name and the git snapshot come from
# docs/research/2026-11-10-hyprland-session-assessment.md (dux-greeter-git-2.1.3)
# and CHANGELOG.md's +git entry (git132.7bdf4546).
git_extra=$work/git-extra.lock
cat >"$git_extra" <<'LOCK'
dux-greeter-git-2:2.1.3+git132.7bdf4546-2.fc45.x86_64	copr:copr.fedorainfracloud.org:duxlabs:dux-repo
mesa-vulkan-drivers-1:26.2.6-1.fc45.i686	rpmfusion-free
mesa-vulkan-drivers-1:26.2.6-1.fc45.x86_64	rpmfusion-free
steam-0:1.0.0.87-4.fc45.x86_64	rpmfusion-nonfree
LOCK
status=0
"$compare" "$recorded" "$git_extra" >"$work/out" 2>"$work/err" || status=$?
if ((status != 0)); then
  echo "FAIL a measurement +git line exited ${status}, expected 0" >&2
  failures=$((failures + 1))
else
  echo "ok   a +git line in the measurement alone is not drift"
fi

# Case 6 is the same class in the other encoding. duxlabs publishes
# dux-qt-base-git as a '^<count>.git<sha>' version, which the +git substring
# test missed, so the line was recorded and later reddened the gate. The NEVRA
# is copied from run 45780444809, which failed on it.
snapshot_extra=$work/snapshot-extra.lock
cat >"$snapshot_extra" <<'LOCK'
dux-qt-base-git-0:0.4.74^967.git1f768a3-1.fc45.x86_64	copr:copr.fedorainfracloud.org:duxlabs:dux-repo
mesa-vulkan-drivers-1:26.2.6-1.fc45.i686	rpmfusion-free
mesa-vulkan-drivers-1:26.2.6-1.fc45.x86_64	rpmfusion-free
steam-0:1.0.0.87-4.fc45.x86_64	rpmfusion-nonfree
LOCK
status=0
"$compare" "$recorded" "$snapshot_extra" >"$work/out" 2>"$work/err" || status=$?
if ((status != 0)); then
  echo "FAIL a measurement git snapshot exited ${status}, expected 0" >&2
  failures=$((failures + 1))
elif [[ -s $work/err ]]; then
  echo "FAIL the comparator warned about a dropped snapshot instead of staying silent" >&2
  failures=$((failures + 1))
else
  echo "ok   a git snapshot in the measurement is dropped in silence"
fi

# Case 7 is the same rebuild rule on a name with hyphens and digits, and on a
# line the reduction does not recognise. The first must warn; the second must
# block, because an unparsed line is not a pair the comparator can vouch for.
tricky_recorded=$work/tricky-recorded.lock
cat >"$tricky_recorded" <<'LOCK'
dms-cli-0:2.1.2-1.fc45.x86_64	copr:copr.fedorainfracloud.org:duxlabs:dms
weird-1.0-2.fc45.x86_64	rpmfusion-free
LOCK
tricky_rebuilt=$work/tricky-rebuilt.lock
cat >"$tricky_rebuilt" <<'LOCK'
dms-cli-0:2.1.3-1.fc45.x86_64	copr:copr.fedorainfracloud.org:duxlabs:dms
weird-1.0-2.fc45.x86_64	rpmfusion-free
LOCK
status=0
"$compare" "$tricky_recorded" "$tricky_rebuilt" >"$work/out" 2>"$work/err" || status=$?
if ((status != 0)) || ! grep -qF 'warning:' "$work/err"; then
  echo "FAIL a hyphenated name's rebuild did not warn (exit ${status})" >&2
  failures=$((failures + 1))
else
  echo "ok   a hyphenated name with digits reduces to its package name"
fi

tricky_unparsed=$work/tricky-unparsed.lock
cat >"$tricky_unparsed" <<'LOCK'
dms-cli-0:2.1.2-1.fc45.x86_64	copr:copr.fedorainfracloud.org:duxlabs:dms
weird-1.1-2.fc45.x86_64	rpmfusion-free
LOCK
status=0
"$compare" "$tricky_recorded" "$tricky_unparsed" >"$work/out" 2>"$work/err" || status=$?
if ((status != 1)); then
  echo "FAIL an unrecognised NEVRA shape exited ${status}, expected 1" >&2
  failures=$((failures + 1))
else
  echo "ok   an unrecognised NEVRA shape blocks instead of warning"
fi

: >"$work/empty.lock"
status=0
"$compare" "$recorded" "$work/empty.lock" >"$work/out" 2>"$work/err" || status=$?
if ((status != 2)); then
  echo "FAIL an empty measurement exited ${status}, expected 2 (not drift)" >&2
  failures=$((failures + 1))
else
  echo "ok   an empty measurement exits 2, not the drift code"
fi

status=0
"$compare" "$recorded" "$work/absent.lock" >"$work/out" 2>"$work/err" || status=$?
if ((status != 2)); then
  echo "FAIL an unreadable measurement exited ${status}, expected 2 (not drift)" >&2
  failures=$((failures + 1))
else
  echo "ok   an unreadable measurement exits 2, not the drift code"
fi

if ((failures > 0)); then
  exit 1
fi
