#!/usr/bin/env bash
# The disk build retries exactly one signature, once.
#
# bootc-image-builder intermittently fails its manifest step with 'cpio:
# premature end of archive' on an initramfs that is byte-identical in the image
# and reads clean in the same builder (#173). The retry must absorb that
# transient and nothing else: a real builder error still fails the step, on the
# first attempt.
#
#   tests/test-disk-retry.sh

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
attempt=$(( $(cat "$work/attempts" 2>/dev/null || printf 0) + 1 ))
printf '%s\n' "$attempt" >"$work/attempts"
printf '%s\n' "$*" >>"$work/calls"
mode=$(cat "$work/mode")
case "$mode" in
  success) exit 0 ;;
  other)
    echo "error: cannot build manifest: something else broke" >&2
    exit 1
    ;;
  signature)
    if ((attempt == 1)); then
      echo "cpio: premature end of archive" >&2
      exit 1
    fi
    exit 0
    ;;
  always-signature)
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

# Reset the stub, run the real script, and report its status and builder calls.
run_case() {
  local mode=$1
  printf '%s\n' "$mode" >"$work/mode"
  rm -f "$work/attempts" "$work/calls"
  set +e
  err=$(tests/vm/make-disk.sh localhost/ultus-atomic:test "$work/output" 2>&1)
  status=$?
  set -e
  calls=$(wc -l <"$work/calls" 2>/dev/null || printf 0)
}

cd "$repo_root"

run_case success
[[ $status == 0 ]] || fail "a clean build exited $status: $err"
[[ $calls == 1 ]] || fail "a clean build called the builder $calls times"
[[ $err != *'retrying once'* ]] || fail "a clean build reported a retry"
[[ $(sed -n 1p "$work/calls") == *'--type qcow2'* ]] || fail "the builder lost its disk arguments"
pass "a clean build runs the builder once"

run_case signature
[[ $status == 0 ]] || fail "a transient initramfs read exited $status: $err"
[[ $calls == 2 ]] || fail "a transient initramfs read called the builder $calls times"
[[ $err == *'issue #173'* ]] || fail "the retry did not name #173"
pass "the known transient initramfs read is retried once and passes"

run_case other
[[ $status != 0 ]] || fail "an unrelated builder error exited 0"
[[ $calls == 1 ]] || fail "an unrelated builder error was retried ($calls calls)"
pass "an unrelated builder error fails on the first attempt"

run_case always-signature
[[ $status != 0 ]] || fail "a repeated initramfs read error exited 0"
[[ $calls == 2 ]] || fail "a repeated initramfs read error made $calls calls, not 2"
pass "a repeated initramfs read error fails after one retry"

((failures == 0)) || {
  echo "$failures failure(s)" >&2
  exit 1
}
