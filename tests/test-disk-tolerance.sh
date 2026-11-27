#!/usr/bin/env bash
# Only the #173 builder signature is tolerated, and only by the caller that
# knows how to skip the boot smoke.
#
# bootc-image-builder intermittently fails its manifest step with 'cpio:
# premature end of archive' on an initramfs that is byte-identical in the image
# and reads clean in the same builder (#173). build-disk.sh must report that
# signature as exit 3 and nothing else, so a real builder error still reds the
# job on the first attempt.
#
#   tests/test-disk-tolerance.sh

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin" "$work/output"
# The stub answers the storage check, then records each builder invocation and
# fails according to the mode file.
cat >"$work/bin/podman" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
work=${STUB_WORK:?}
if [[ $1 == image ]]; then
  exit 0
fi
printf '%s\n' "$*" >>"$work/calls"
mode=$(cat "$work/mode")
case "$mode" in
  success) exit 0 ;;
  other)
    echo "error: cannot build manifest: something else broke" >&2
    exit 1
    ;;
  signature)
    echo "2026/11/27 07:10:51 error: cannot build manifest: failed to run lsinitrd --mod --kver 7.3.3-300.fc45.x86_64: exit status 4" >&2
    echo "cpio: premature end of archive" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$work/bin/podman"
export STUB_WORK=$work
PATH=$work/bin:$PATH

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok   $*"; }

run_case() {
  local mode=$1
  printf '%s\n' "$mode" >"$work/mode"
  rm -f "$work/calls"
  set +e
  err=$(tests/vm/build-disk.sh localhost/ultus-atomic:test "$work/output" 2>&1)
  status=$?
  set -e
  calls=$(wc -l <"$work/calls" 2>/dev/null || printf 0)
}

cd "$repo_root"

run_case success
[[ $status == 0 ]] || fail "a clean build exited $status: $err"
[[ $calls == 1 ]] || fail "a clean build called the builder $calls times"
pass "a clean build exits 0 after one builder run"

run_case signature
[[ $status == 3 ]] || fail "the #173 signature exited $status, not 3: $err"
[[ $calls == 1 ]] || fail "the #173 signature called the builder $calls times"
[[ $err == *'#173'* ]] || fail "the skip did not name #173"
pass "the #173 signature asks for a skip and names the issue"

run_case other
[[ $status == 1 ]] || fail "an unrelated builder error exited $status, not 1: $err"
[[ $calls == 1 ]] || fail "an unrelated builder error called the builder $calls times"
[[ $err != *'skipping the boot smoke'* ]] || fail "an unrelated builder error claimed a skip"
pass "an unrelated builder error keeps its status"

run_case signature
[[ $status == 3 ]] || fail "a repeated #173 signature exited $status, not 3: $err"
pass "the tolerance does not grow into a retry loop"

((failures == 0)) || {
  echo "$failures failure(s)" >&2
  exit 1
}
