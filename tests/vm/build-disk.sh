#!/usr/bin/env bash
# Build the disposable qcow2 from the image in local rootful podman storage.
#
# bootc-image-builder intermittently fails its manifest step with 'cpio:
# premature end of archive' on an initramfs that is byte-identical to the
# artifact and reads clean in the same builder (#173). Exit 3 for that exact
# signature so the caller can skip the boot smoke; every other failure keeps
# its own status.
#
#   tests/vm/build-disk.sh <image> <out>

set -euo pipefail

image=${1:?usage: build-disk.sh <image> <out>}
out=${2:?usage: build-disk.sh <image> <out>}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

log=$(mktemp)
trap 'rm -f "$log"' EXIT

set +e
"$repo_root/tests/vm/make-disk.sh" "$image" "$out" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e
if ((status == 0)); then
  exit 0
fi
if grep -qF 'failed to run lsinitrd --mod' "$log" &&
  grep -qF 'cpio: premature end of archive' "$log"; then
  echo "warning: the builder failed the #173 initramfs read; skipping the boot smoke" >&2
  exit 3
fi
exit "$status"
