#!/usr/bin/env bash
# Run ultus-env against fixture secrets and assert what it wrote, with no host
# service manager and no hidden dependency on the caller's environment.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
runtime=${CONTAINER_RUNTIME:-}
if [[ -z $runtime ]]; then
  for candidate in podman docker; do
    if command -v "$candidate" >/dev/null 2>&1; then
      runtime=$candidate
      break
    fi
  done
fi
[[ -n $runtime ]] || { echo "need podman or docker" >&2; exit 2; }
script=$repo_root/modules/server/usr/libexec/ultus/ultus-env
fixtures=$repo_root/tests/fixtures

# The same base the image builds on, so the test cannot drift onto a newer daily
# tag than the image ships.
if [[ -z ${TEST_IMAGE:-} ]]; then
  TEST_IMAGE=$(grep -oE 'registry\.fedoraproject\.org/fedora-bootc:45@sha256:[0-9a-f]{64}' "$repo_root/Containerfile" | head -1)
  [[ -n $TEST_IMAGE ]] || { echo "FAIL could not read the base pin from Containerfile" >&2; exit 1; }
fi
image=$TEST_IMAGE

# Run the script inside the image with /var/srv and /run bind-mapped, so the
# `mountpoint` check sees a real mount. A tmpfs on /var/srv is that mount.
run_case() {
  local secrets=$1 workload=$2
  "$runtime" run --rm \
    --mount "type=bind,src=${secrets},dst=/secrets.env,ro" \
    --mount "type=bind,src=${script},dst=/ultus-env,ro" \
    --tmpfs /var/srv --tmpfs /run \
    --entrypoint bash "$image" -c "
      groupadd -g 1000 agents
      useradd -u 1000 -g agents -M -d /var/lib/agents -s /sbin/nologin agents
      install -d -m 0700 /var/srv/ultus
      cp /secrets.env /var/srv/ultus/secrets.env
      chmod 0600 /var/srv/ultus/secrets.env
      /ultus-env ${workload}
      stat -c '%a %U:%G' /run/ultus/${workload}.env
      sort /run/ultus/${workload}.env
    "
}

out=$(run_case "$fixtures/server-secrets.txt" opencode)
grep -qx '600 agents:agents' <<<"$out" || { echo "FAIL the opencode env is not 0600 agents:agents: $out" >&2; exit 1; }
grep -qx 'OPENCODE_PASSWORD=server-secret' <<<"$out" || { echo "FAIL the opencode password is missing from the derived env" >&2; exit 1; }
if grep -q 'API_SERVER_KEY' <<<"$out"; then
  echo "FAIL the opencode env carries a key only Hermes needs" >&2
  exit 1
fi
echo "ok   the opencode env holds its own keys, 0600, owned by agents"

out=$(run_case "$fixtures/server-secrets.txt" hermes)
grep -qx 'API_SERVER_KEY=api-key' <<<"$out" || { echo "FAIL the Hermes env is missing its API key" >&2; exit 1; }
grep -qx 'OPENROUTER_API_KEY=provider-key' <<<"$out" || { echo "FAIL the Hermes env is missing the provider key" >&2; exit 1; }
echo "ok   the Hermes env holds the required keys and the provider key"

for role in opencode hermes; do
  rc=0
  out=$(run_case "$fixtures/server-secrets-partial.txt" "$role" 2>&1) || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "FAIL ultus-env ${role} accepted a secrets file with no password" >&2
    exit 1
  fi
  echo "ok   ultus-env ${role} failed closed on a missing required key"
done

echo "server env tests passed"
